import AppKit
import AVKit
import PugglePhotosKit

protocol ViewerDelegate: AnyObject {
    var library: LibraryController { get }
    /// The photos the viewer steps through, in order.
    var viewerSequence: [PhotoID] { get }
    func viewerDidShow(_ id: PhotoID)
    func viewerClose()
}

/// One photo or video, as big as the window allows, on a dark background. ← and → step through the photos,
/// Esc goes back, and pinching, double-clicking or ⌘+ zooms in.
final class ViewerViewController: NSViewController {
    weak var delegate: ViewerDelegate?
    private(set) var currentID: PhotoID?
    private let photoView = ZoomingPhotoView()
    private let playerView = AVPlayerView()
    private let captionField = NSTextField(wrappingLabelWithString: "")
    private let captionBackground = NSVisualEffectView()
    private let previousButton = ViewerArrowButton(symbol: "chevron.left", label: "Previous")
    private let nextButton = ViewerArrowButton(symbol: "chevron.right", label: "Next")
    private var request: ImageRequest?
    private var playerItemID: PhotoID?

    override func loadView() {
        let root = ViewerRootView()
        root.owner = self
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.viewerBackground.cgColor
        photoView.translatesAutoresizingMaskIntoConstraints = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .floating
        playerView.isHidden = true
        captionBackground.material = .hudWindow
        captionBackground.blendingMode = .withinWindow
        captionBackground.state = .active
        captionBackground.wantsLayer = true
        captionBackground.layer?.cornerRadius = 10
        captionBackground.translatesAutoresizingMaskIntoConstraints = false
        captionField.font = .systemFont(ofSize: 15, weight: .medium)
        captionField.textColor = .white
        captionField.alignment = .center
        captionField.translatesAutoresizingMaskIntoConstraints = false
        captionBackground.addSubview(captionField)
        for view in [photoView, playerView, captionBackground, previousButton, nextButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        previousButton.target = self
        previousButton.action = #selector(showPrevious(_:))
        nextButton.target = self
        nextButton.action = #selector(showNext(_:))
        NSLayoutConstraint.activate([
            photoView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            photoView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            photoView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            photoView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            playerView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 16),
            playerView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            captionBackground.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            captionBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            captionBackground.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.7),
            captionField.leadingAnchor.constraint(equalTo: captionBackground.leadingAnchor, constant: 16),
            captionField.trailingAnchor.constraint(equalTo: captionBackground.trailingAnchor, constant: -16),
            captionField.topAnchor.constraint(equalTo: captionBackground.topAnchor, constant: 8),
            captionField.bottomAnchor.constraint(equalTo: captionBackground.bottomAnchor, constant: -8),
            previousButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            previousButton.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            nextButton.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        photoView.onDoubleClick = { [weak self] in self?.photoView.toggleZoom() }
        root.setAccessibilityLabel("Viewer")
        view = root
    }

    /// Shows a photo or video.
    func show(_ id: PhotoID) {
        guard let library = delegate?.library, let item = library.snapshot.item(id) else { return }
        let changed = currentID != id
        currentID = id
        updateCaption()
        updateArrows()
        if item.kind.isVideo {
            photoView.isHidden = true
            playerView.isHidden = false
            request?.cancel()
            photoView.image = nil
            if changed || playerView.player == nil {
                playerView.player?.pause()
                playerView.player = nil
                playerItemID = id
                library.source.requestPlayerItem(id) { [weak self] playerItem in
                    guard let self, playerItemID == id, let playerItem else { return }
                    let player = AVPlayer(playerItem: playerItem)
                    playerView.player = player
                    if !SelfTestMode.isRunning { player.play() }
                }
            }
        } else {
            playerView.player?.pause()
            playerView.player = nil
            playerItemID = nil
            playerView.isHidden = true
            photoView.isHidden = false
            guard changed || photoView.image == nil else { return }
            photoView.resetZoom()
            // A thumbnail at once, then the full picture sized for the screen.
            let screen = (view.window?.screen?.frame.size ?? NSSize(width: 2560, height: 1600))
            let scale = view.window?.backingScaleFactor ?? 2
            photoView.image = library.thumbnails.cached(id, pixels: 512) ?? library.thumbnails.cached(id, pixels: 256)
            photoView.aspect = CGFloat(item.aspectRatio)
            request?.cancel()
            request = library.source.requestImage(id, pixels: CGSize(width: screen.width * scale, height: screen.height * scale),
                                                  fit: true) { [weak self] image, _ in
                guard let self, currentID == id, let image else { return }
                photoView.image = image
            }
        }
        delegate?.viewerDidShow(id)
    }

    var hasPlayer: Bool { playerView.player != nil }

    /// Stops any video and lets go of the picture, when the viewer closes.
    func stop() {
        playerView.player?.pause()
        playerView.player = nil
        playerItemID = nil
        request?.cancel()
        request = nil
        currentID = nil
        photoView.image = nil
    }

    func updateCaption() {
        guard let id = currentID, let library = delegate?.library else { return }
        let caption = library.catalog.photos[id]?.caption ?? ""
        captionField.stringValue = caption
        captionBackground.isHidden = caption.isEmpty
    }

    private func updateArrows() {
        let sequence = delegate?.viewerSequence ?? []
        let index = currentID.flatMap { sequence.firstIndex(of: $0) }
        previousButton.isHidden = index == nil || index == 0
        nextButton.isHidden = index == nil || index == sequence.count - 1
    }

    @objc func showPrevious(_ sender: Any?) { step(-1) }
    @objc func showNext(_ sender: Any?) { step(1) }

    func step(_ offset: Int) {
        let sequence = delegate?.viewerSequence ?? []
        guard let current = currentID, let index = sequence.firstIndex(of: current) else { return }
        let target = index + offset
        guard sequence.indices.contains(target) else {
            NSSound.beep()
            return
        }
        show(sequence[target])
    }

    func zoom(by factor: CGFloat) { photoView.zoom(by: factor) }
    func zoomToFit() { photoView.resetZoom() }

    fileprivate func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: step(-1)
        case 124: step(1)
        case 53: delegate?.viewerClose()
        case 49:
            if let player = playerView.player, !playerView.isHidden {
                if player.rate == 0 { player.play() } else { player.pause() }
            } else {
                delegate?.viewerClose()
            }
        default: return false
        }
        return true
    }
}

/// The viewer's background view, which takes the arrow keys.
final class ViewerRootView: NSView {
    fileprivate weak var owner: ViewerViewController?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if owner?.key(event) != true { super.keyDown(with: event) }
    }
}

/// A round translucent button at the side of the viewer.
final class ViewerArrowButton: NSButton {
    init(symbol: String, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .white
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.cornerRadius = 22
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A picture fitted to the view, which can be zoomed (pinch, double-click, ⌘+ and ⌘−) and dragged around.
final class ZoomingPhotoView: NSView {
    private let imageLayer = CALayer()
    var image: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = image
            CATransaction.commit()
            needsLayout = true
        }
    }
    /// Width over height, known before the picture arrives.
    var aspect: CGFloat = 4.0 / 3.0 { didSet { needsLayout = true } }
    var onDoubleClick: (() -> Void)?
    private(set) var zoomScale: CGFloat = 1
    private var offset = CGPoint.zero
    private var dragStart: (point: NSPoint, offset: CGPoint)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        setAccessibilityRole(.image)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var imageAspect: CGFloat {
        if let image, image.height > 0 { return CGFloat(image.width) / CGFloat(image.height) }
        return aspect
    }

    override func layout() {
        super.layout()
        let area = bounds.insetBy(dx: 24, dy: 20)
        guard area.width > 0, area.height > 0 else { return }
        var size = CGSize(width: area.width, height: area.width / imageAspect)
        if size.height > area.height { size = CGSize(width: area.height * imageAspect, height: area.height) }
        size = CGSize(width: size.width * zoomScale, height: size.height * zoomScale)
        clampOffset(for: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(x: bounds.midX - size.width / 2 + offset.x, y: bounds.midY - size.height / 2 + offset.y,
                                  width: size.width, height: size.height)
        CATransaction.commit()
    }

    private func clampOffset(for size: CGSize) {
        let maxX = max(0, (size.width - bounds.width) / 2), maxY = max(0, (size.height - bounds.height) / 2)
        offset = CGPoint(x: min(max(offset.x, -maxX), maxX), y: min(max(offset.y, -maxY), maxY))
    }

    func resetZoom() {
        zoomScale = 1
        offset = .zero
        needsLayout = true
    }

    func zoom(by factor: CGFloat) {
        zoomScale = min(max(zoomScale * factor, 1), 8)
        if zoomScale == 1 { offset = .zero }
        needsLayout = true
    }

    func toggleZoom() {
        if zoomScale > 1 { resetZoom() } else { zoom(by: 2.5) }
    }

    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification) }

    override func scrollWheel(with event: NSEvent) {
        guard zoomScale > 1 else { return super.scrollWheel(with: event) }
        offset.x += event.scrollingDeltaX
        offset.y -= event.scrollingDeltaY
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragStart = (convert(event.locationInWindow, from: nil), offset)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, zoomScale > 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        offset = CGPoint(x: dragStart.offset.x + point.x - dragStart.point.x, y: dragStart.offset.y + point.y - dragStart.point.y)
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }
}

/// Whether the self-test is driving the app, so videos don't start playing sound.
enum SelfTestMode {
    static var isRunning = false
}
