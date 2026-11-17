import AppKit
import AVFoundation
import CoreImage
import PugglePhotosKit

/// Plays a memory full screen: a title card, then each photo with a slow pan and zoom and each video in place,
/// crossfading from one to the next, over music, with a bar of segments at the top showing how far it's got.
/// Click the right of the screen (or press →) for the next photo, the left (or ←) for the one before; Space pauses
/// and Esc ends it.
final class SlideshowController: NSObject {
    private(set) static var current: SlideshowController?

    let memory: Memory
    let slides: [Slide]
    private(set) var index = 0
    private(set) var isPaused = false
    private let library: LibraryController
    let window: SlideshowWindow
    let stage: SlideshowStageView
    let controls: SlideshowControlsView
    let music = SlideshowMusic()
    /// Called when the slideshow ends: true when the person asked to see the photos.
    var onClose: ((Bool) -> Void)?
    /// For screenshots: stops all motion this far (0 to 1) into each slide.
    var frozenProgress: Double?

    private var images: [PhotoID: CGImage] = [:]
    private var backdrops: [PhotoID: CGImage] = [:]
    private var requests: [PhotoID: ImageRequest] = [:]
    private var timer: Timer?
    private var tick: Timer?
    private var slideStarted = Date()
    private var elapsedBeforePause: TimeInterval = 0
    private var player: AVPlayer?
    private var playerObserver: NSObjectProtocol?
    private var slideLayer: SlideLayer?

    /// Starts a slideshow on the screen given (or the main one), ending any other.
    @discardableResult
    static func play(_ memory: Memory, library: LibraryController, on screen: NSScreen?, onClose: ((Bool) -> Void)? = nil) -> SlideshowController {
        current?.close()
        let controller = SlideshowController(memory: memory, library: library, screen: screen ?? NSScreen.main)
        controller.onClose = onClose
        current = controller
        controller.begin()
        return controller
    }

    private init(memory: Memory, library: LibraryController, screen: NSScreen?) {
        self.memory = memory
        self.library = library
        slides = SlideshowPlan.make(memory, items: library.snapshot.item, secondsPerPhoto: MemoryPreferences.secondsPerPhoto)
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = SlideshowWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        stage = SlideshowStageView(frame: NSRect(origin: .zero, size: frame.size))
        controls = SlideshowControlsView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()
        window.controller = self
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = memory.title
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        stage.autoresizingMask = [.width, .height]
        controls.autoresizingMask = [.width, .height]
        container.addSubview(stage)
        container.addSubview(controls)
        window.contentView = container
        window.setFrame(frame, display: false)
        stage.controller = self
        controls.controller = self
        controls.configure(title: memory.title, subtitle: memory.subtitle, segments: slides.filter(\.isCounted).count)
    }

    private func begin() {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(stage)
        NSApp.activate()
        NSCursor.setHiddenUntilMouseMoves(true)
        music.start()
        show(0, animated: false)
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
    }

    // MARK: Moving through the slides

    var slide: Slide { slides[index] }

    /// Where the counted slides (photos and videos) have got to, for the progress bar.
    private var countedIndex: Int { slides[..<index].filter(\.isCounted).count }

    func next() {
        guard index < slides.count - 1 else { return }
        if isPaused { setPaused(false) }
        show(index + 1)
    }

    func previous() {
        guard index > 0 else {
            show(0)
            return
        }
        if isPaused { setPaused(false) }
        show(index - 1)
    }

    func playAgain() {
        if isPaused { setPaused(false) }
        if !music.isPlaying { music.start() }
        show(0)
    }

    func togglePause() { setPaused(!isPaused) }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused, slide.duration > 0 else { return }
        isPaused = paused
        if paused {
            timer?.invalidate()
            elapsedBeforePause += Date().timeIntervalSince(slideStarted)
            stage.finishTransition()
            stage.pauseMotion()
            player?.pause()
            music.pause()
        } else {
            slideStarted = Date()
            stage.resumeMotion()
            player?.play()
            music.resume()
            scheduleAdvance(after: max(0.1, slide.duration - elapsedBeforePause))
        }
        controls.update(paused: isPaused, musicMuted: music.isMuted, atEnd: slide.duration == 0)
    }

    func toggleMusic() {
        music.toggleMute()
        controls.update(paused: isPaused, musicMuted: music.isMuted, atEnd: slide.duration == 0)
    }

    /// How far into the current slide, 0 to 1.
    var slideProgress: Double {
        guard slide.duration > 0 else { return 1 }
        if let frozenProgress { return frozenProgress }
        let elapsed = elapsedBeforePause + (isPaused ? 0 : Date().timeIntervalSince(slideStarted))
        return min(1, elapsed / slide.duration)
    }

    private func updateProgress() {
        controls.setProgress(segment: countedIndex, fraction: slide.isCounted ? slideProgress : 0, finished: slide.duration == 0)
    }

    private func scheduleAdvance(after seconds: TimeInterval) {
        timer?.invalidate()
        guard frozenProgress == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
    }

    private func show(_ newIndex: Int, animated: Bool = true) {
        timer?.invalidate()
        stopVideo()
        let begin = stage.currentTime
        index = newIndex
        let slide = slides[index]
        let layer = SlideLayer()
        layer.frame = stage.bounds
        layer.contentsScale = window.backingScaleFactor
        fill(layer, for: slide)
        stage.present(layer, animated: animated, transition: SlideshowPlan.transition)
        slideLayer = layer
        slideStarted = Date()
        elapsedBeforePause = 0
        controls.update(paused: false, musicMuted: music.isMuted, atEnd: slide.duration == 0)
        updateProgress()
        prefetch()
        if case let .video(id) = slide.content { startVideo(id, in: layer) }
        if slide.duration > 0 { scheduleAdvance(after: slide.duration) }
        if let frozenProgress {
            // After the slide's animations have begun, so they're caught partway rather than before they start.
            let seconds = frozenProgress * (slide.duration + SlideshowPlan.transition)
            DispatchQueue.main.async { [weak self] in
                self?.stage.finishTransition()
                self?.stage.freeze(at: seconds, from: begin)
            }
        }
    }

    /// Ends the slideshow, fading out the music.
    func close(showPhotos: Bool = false) {
        guard Self.current === self else { return }
        timer?.invalidate()
        tick?.invalidate()
        stopVideo()
        music.stop()
        requests.values.forEach { $0.cancel() }
        requests = [:]
        NSApp.presentationOptions = []
        window.orderOut(nil)
        Self.current = nil
        onClose?(showPhotos)
    }

    // MARK: Drawing a slide

    private var screenAspect: Double { Double(max(stage.bounds.width, 1) / max(stage.bounds.height, 1)) }

    private func fill(_ layer: SlideLayer, for slide: Slide) {
        switch slide.content {
        case let .title(title, subtitle, photo):
            if let photo { addPhoto(photo, to: layer, duration: slide.duration, dimmed: 0.45) }
            layer.addText(title, subtitle: subtitle, in: stage.bounds, large: true)
        case let .photo(id):
            addPhoto(id, to: layer, duration: slide.duration, dimmed: 0)
            addLabels(for: id, to: layer)
        case let .video(id):
            layer.setBackdrop(backdrops[id] ?? images[id], dim: 0.55)
            addLabels(for: id, to: layer)
        case let .end(title):
            if let photo = memory.keyPhoto {
                layer.setBackdrop(backdrops[photo] ?? images[photo], dim: 0.6)
                layer.backdropPhoto = photo
            }
            layer.addText(title, subtitle: "Play it again, or see every photo.", in: stage.bounds, large: false)
        }
    }

    /// A photo with its slow pan and zoom, over a blurred copy of itself when it doesn't fill the screen.
    private func addPhoto(_ id: PhotoID, to layer: SlideLayer, duration: TimeInterval, dimmed: CGFloat) {
        let aspect = library.snapshot.item(id)?.aspectRatio ?? 1.5
        let motion = KenBurns.motion(imageAspect: aspect, screenAspect: screenAspect, seed: KenBurns.seed(id))
        if !motion.fills {
            layer.setBackdrop(backdrops[id], dim: 0.35)
            layer.backdropPhoto = id
        }
        layer.setPhoto(id, image: images[id], motion: motion, imageAspect: CGFloat(aspect), in: stage.bounds,
                       duration: duration + SlideshowPlan.transition, dim: dimmed)
    }

    /// The day the photo was taken, and its caption.
    private func addLabels(for id: PhotoID, to layer: SlideLayer) {
        let item = library.snapshot.item(id)
        let day = item.map { library.formatting.longDay(CivilDay($0.date, in: library.formatting.timeZone)) } ?? ""
        let caption = library.catalog.photos[id]?.caption ?? ""
        layer.addCaption(caption, date: day, in: stage.bounds)
    }

    // MARK: Pictures and videos

    /// Asks for the pictures of this slide and the next two, and lets go of ones far behind.
    private func prefetch() {
        let wanted = slides[index..<min(slides.count, index + 3)].compactMap(\.photo) + [memory.keyPhoto].compactMap { $0 }
        let keep = Set(wanted + slides[max(0, index - 1)..<index].compactMap(\.photo))
        for id in images.keys where !keep.contains(id) { images[id] = nil }
        for id in requests.keys where !keep.contains(id) {
            requests[id]?.cancel()
            requests[id] = nil
        }
        let scale = window.backingScaleFactor
        let pixels = CGSize(width: stage.bounds.width * scale, height: stage.bounds.height * scale)
        for id in wanted where images[id] == nil && requests[id] == nil {
            requests[id] = library.source.requestImage(id, pixels: pixels, fit: true) { [weak self] image, isFinal in
                guard let self, let image else { return }
                if isFinal { requests[id] = nil }
                images[id] = image
                slideLayer?.photoArrived(id, image: image)
                if backdrops[id] == nil { makeBackdrop(id, from: image) }
            }
        }
    }

    private func makeBackdrop(_ id: PhotoID, from image: CGImage) {
        let source = SendableImage(cgImage: image)
        Task {
            guard let blurred = await Self.blur(source) else { return }
            backdrops[id] = blurred.cgImage
            slideLayer?.backdropArrived(id, image: blurred.cgImage)
        }
    }

    private nonisolated static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// A small, very blurred copy of a picture, to fill the space around one that doesn't fill the screen.
    @concurrent private nonisolated static func blur(_ source: SendableImage) async -> SendableImage? {
        let input = CIImage(cgImage: source.cgImage)
        let scale = 240 / max(input.extent.width, input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: small.extent)
        return context.createCGImage(blurred, from: small.extent).map(SendableImage.init)
    }

    private func startVideo(_ id: PhotoID, in layer: SlideLayer) {
        library.source.requestPlayerItem(id) { [weak self, weak layer] item in
            guard let self, let layer, let item, slideLayer === layer else { return }
            let player = AVPlayer(playerItem: item)
            self.player = player
            layer.setVideo(player, in: stage.bounds)
            music.duck(true)
            playerObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.next() }
            }
            if SelfTestMode.isRunning || SlideshowMusic.isSilenced { player.isMuted = true }
            if !isPaused, frozenProgress == nil { player.play() }
        }
    }

    private func stopVideo() {
        player?.pause()
        player = nil
        if let playerObserver { NotificationCenter.default.removeObserver(playerObserver) }
        playerObserver = nil
        music.duck(false)
    }

    var isPlayingVideo: Bool { player != nil }

    #if DEBUG
    /// The slide's layers, described, for checking screenshots.
    func describeSlide() -> String {
        guard let slideLayer else { return "no slide" }
        let root = slideLayer.superlayer
        var lines = ["root speed=\(root?.speed ?? -1) offset=\(root?.timeOffset ?? -1) layers=\(root?.sublayers?.count ?? 0)"]
        for (index, layer) in (root?.sublayers ?? []).enumerated() {
            lines.append("slide \(index): opacity=\(layer.opacity) presentation=\(layer.presentation()?.opacity ?? -1) frame=\(layer.frame) mine=\(layer === slideLayer)")
        }
        for sub in slideLayer.sublayers ?? [] {
            lines.append("  sub frame=\(sub.frame) presentation=\(sub.presentation()?.frame ?? .zero) contents=\(sub.contents != nil) opacity=\(sub.opacity) hidden=\(sub.isHidden)")
        }
        return lines.joined(separator: "\n")
    }
    #endif

    // MARK: Keys and clicks

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: previous()
        case 124: next()
        case 49: togglePause()
        case 53: close()
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "m" {
                toggleMusic()
                return true
            }
            return false
        }
        return true
    }

    /// A click on the left third goes back; anywhere else goes on.
    func clicked(at point: NSPoint) {
        guard slide.duration > 0 else { return }
        if point.x < stage.bounds.width / 3 { previous() } else { next() }
    }
}

final class SlideshowWindow: NSWindow {
    weak var controller: SlideshowController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if controller?.handle(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { controller?.close() }
}

/// The slideshow's picture: slides crossfading one into the next.
final class SlideshowStageView: NSView {
    weak var controller: SlideshowController?
    private let root = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        root.frame = bounds
        root.isGeometryFlipped = true
        layer?.addSublayer(root)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        CATransaction.commit()
    }

    /// Fades a slide in over the one before, which fades out and goes.
    func present(_ slide: CALayer, animated: Bool, transition: TimeInterval) {
        let outgoing = root.sublayers ?? []
        root.addSublayer(slide)
        guard animated else {
            outgoing.forEach { $0.removeFromSuperlayer() }
            return
        }
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = transition
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        slide.add(fadeIn, forKey: "fadeIn")
        for old in outgoing {
            CATransaction.begin()
            CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.duration = transition
            old.opacity = 0
            old.add(fadeOut, forKey: "fadeOut")
            CATransaction.commit()
        }
    }

    /// Ends a crossfade at once: the new slide shows fully and the ones before it go. A pause shouldn't stop on a
    /// half-faded picture.
    func finishTransition() {
        guard let sublayers = root.sublayers, let newest = sublayers.last else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in sublayers.dropLast() { layer.removeFromSuperlayer() }
        newest.removeAnimation(forKey: "fadeIn")
        newest.opacity = 1
        CATransaction.commit()
    }

    func pauseMotion() {
        let now = root.convertTime(CACurrentMediaTime(), from: nil)
        root.speed = 0
        root.timeOffset = now
    }

    func resumeMotion() {
        let paused = root.timeOffset
        root.speed = 1
        root.timeOffset = 0
        root.beginTime = 0
        root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - paused
    }

    /// The stage's own clock, which stands still while it's paused.
    var currentTime: CFTimeInterval { root.convertTime(CACurrentMediaTime(), from: nil) }

    /// Stops all motion `seconds` after `start` (a time on the stage's clock), for screenshots.
    func freeze(at seconds: TimeInterval, from start: CFTimeInterval) {
        root.speed = 0
        root.timeOffset = start + seconds
    }

    override func mouseUp(with event: NSEvent) {
        controller?.clicked(at: convert(event.locationInWindow, from: nil))
    }
}

/// One slide's layers: a backdrop, the photo (or video) and its words.
nonisolated final class SlideLayer: CALayer {
    private(set) var photoID: PhotoID?
    var backdropPhoto: PhotoID?
    private let backdrop = CALayer()
    private let backdropShade = CALayer()
    private let photo = CALayer()
    private let photoShade = CALayer()
    private var playerLayer: AVPlayerLayer?

    override init() {
        super.init()
        // The stage's root layer is already flipped, so (0, 0) is the top left here too.
        masksToBounds = true
        backgroundColor = NSColor.black.cgColor
        backdrop.contentsGravity = .resizeAspectFill
        backdropShade.backgroundColor = NSColor.black.cgColor
        backdropShade.opacity = 0
        photo.contentsGravity = .resize
        photo.minificationFilter = .trilinear
        photoShade.backgroundColor = NSColor.black.cgColor
        photoShade.opacity = 0
        for layer in [backdrop, backdropShade, photo, photoShade] { addSublayer(layer) }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setBackdrop(_ image: CGImage?, dim: Float) {
        backdrop.frame = bounds.insetBy(dx: -40, dy: -40)
        backdrop.contents = image
        backdropShade.frame = bounds
        backdropShade.opacity = dim
    }

    func backdropArrived(_ id: PhotoID, image: CGImage) {
        guard backdropPhoto == id else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        backdrop.contents = image
        CATransaction.commit()
    }

    /// The photo, moving from one part of it to another over `duration`.
    func setPhoto(_ id: PhotoID, image: CGImage?, motion: KenBurns, imageAspect: CGFloat, in bounds: CGRect,
                  duration: TimeInterval, dim: CGFloat) {
        photoID = id
        photo.contents = image
        let start = Self.frame(showing: motion.from, imageAspect: imageAspect, fills: motion.fills, in: bounds)
        let end = Self.frame(showing: motion.to, imageAspect: imageAspect, fills: motion.fills, in: bounds)
        photo.frame = end
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: NSPoint(x: start.midX, y: start.midY))
        position.toValue = NSValue(point: NSPoint(x: end.midX, y: end.midY))
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = NSValue(size: start.size)
        size.toValue = NSValue(size: end.size)
        let group = CAAnimationGroup()
        group.animations = [position, size]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        photo.add(group, forKey: "kenBurns")
        photoShade.frame = bounds
        photoShade.opacity = Float(dim)
    }

    func photoArrived(_ id: PhotoID, image: CGImage) {
        if photoID == id {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            photo.contents = image
            CATransaction.commit()
        }
        if backdropPhoto == id, backdrop.contents == nil { backdrop.contents = image }
    }

    /// Where the photo goes so that `rect` (a part of it, in unit coordinates) fills the screen, or, for a photo
    /// that sits whole, the largest space of its shape in the middle of the screen.
    static func frame(showing rect: CGRect, imageAspect: CGFloat, fills: Bool, in bounds: CGRect) -> CGRect {
        var viewport = bounds
        if !fills {
            let shape = rect.width * imageAspect / rect.height
            let fitted = bounds.width / bounds.height > shape
                ? CGSize(width: bounds.height * shape, height: bounds.height)
                : CGSize(width: bounds.width, height: bounds.width / shape)
            let inset = CGSize(width: fitted.width * 0.92, height: fitted.height * 0.92)
            viewport = CGRect(x: bounds.midX - inset.width / 2, y: bounds.midY - inset.height / 2, width: inset.width, height: inset.height)
        }
        let width = viewport.width / rect.width, height = viewport.height / rect.height
        return CGRect(x: viewport.minX - rect.minX * width, y: viewport.minY - rect.minY * height, width: width, height: height)
    }

    func setVideo(_ player: AVPlayer, in bounds: CGRect) {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = bounds.insetBy(dx: bounds.width * 0.04, dy: bounds.height * 0.06)
        insertSublayer(layer, above: backdropShade)
        playerLayer = layer
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight, in bounds: CGRect, y: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        layer.string = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        layer.isWrapped = true
        layer.alignmentMode = .center
        layer.contentsScale = contentsScale
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 10
        layer.shadowOffset = .zero
        let width = min(bounds.width - 120, 1100)
        let height = ceil((string as NSString).boundingRect(with: CGSize(width: width, height: 600), options: [.usesLineFragmentOrigin],
                                                            attributes: [.font: font]).height) + 8
        layer.frame = CGRect(x: bounds.midX - width / 2, y: y, width: width, height: height)
        return layer
    }

    /// A big title and its subtitle in the middle of the screen.
    func addText(_ title: String, subtitle: String, in bounds: CGRect, large: Bool) {
        let titleLayer = text(title, size: large ? min(76, bounds.width / 16) : 54, weight: .heavy, in: bounds, y: 0)
        let subtitleLayer = text(subtitle, size: large ? 26 : 22, weight: .medium, in: bounds, y: 0)
        let total = titleLayer.frame.height + 10 + subtitleLayer.frame.height
        titleLayer.frame.origin.y = bounds.midY - total / 2 - (large ? 0 : 60)
        subtitleLayer.frame.origin.y = titleLayer.frame.maxY + 10
        subtitleLayer.opacity = 0.9
        addSublayer(titleLayer)
        addSublayer(subtitleLayer)
    }

    /// The photo's caption near the bottom, and its date in the corner.
    func addCaption(_ caption: String, date: String, in bounds: CGRect) {
        if !date.isEmpty {
            let dateLayer = text(date, size: 17, weight: .semibold, in: bounds, y: 0)
            let width = min(dateLayer.frame.width, 520)
            dateLayer.alignmentMode = .left
            if let string = dateLayer.string as? NSAttributedString {
                let left = NSMutableAttributedString(attributedString: string)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .left
                left.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: left.length))
                dateLayer.string = left
            }
            dateLayer.frame = CGRect(x: 44, y: bounds.maxY - 44 - dateLayer.frame.height, width: width, height: dateLayer.frame.height)
            dateLayer.opacity = 0.85
            addSublayer(dateLayer)
        }
        guard !caption.isEmpty else { return }
        let captionLayer = text(caption, size: 30, weight: .bold, in: bounds, y: 0)
        captionLayer.frame.origin.y = bounds.maxY - 110 - captionLayer.frame.height
        addSublayer(captionLayer)
    }
}
