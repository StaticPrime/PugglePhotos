import AppKit
import AVFoundation
import PugglePhotosKit

/// What the book view asks of its controller.
protocol BookViewDelegate: AnyObject {
    var layout: BookLayout { get }
    /// A page as a picture, at the view's resolution; nil for none.
    func pageImage(_ page: Int) -> CGImage?
    func bookDidChangeState(_ state: Int)
    func bookSelectionDidChange(_ id: PhotoID?)
    func bookOpenPhoto(_ id: PhotoID)
    /// What VoiceOver says for a photo in the book.
    func bookDescription(of id: PhotoID) -> String
    /// Where in the book a place is, for VoiceOver.
    func bookPlace(_ state: Int) -> String
    /// While a photo is dragged or turned: draw its page with it there.
    func bookPreview(_ id: PhotoID, center: CGPoint?, angle: Double?)
    /// When the drag or turn ends.
    func bookCommit(_ id: PhotoID, center: CGPoint?, angle: Double?)
    func bookPlayer(for id: PhotoID, completion: @escaping @MainActor (AVPlayer?) -> Void)
    var alwaysPlaysVideos: Bool { get }
    var playsVideoSound: Bool { get }
}

/// A photo book open on a desk: two pages side by side (or the closed cover), turned with a real-looking page turn.
/// Click the paper to turn a page, or drag it over; click a photo to pick it, then drag it or its round handle to
/// move or turn it. Videos play while the pointer is over them.
final class BookView: NSView {
    weak var delegate: BookViewDelegate?
    private(set) var state = 0
    private(set) var selected: PhotoID?
    private let desk = CAGradientLayer()
    private let book = CALayer()
    private let bookShadow = CALayer()
    private let leftPage = CALayer()
    private let rightPage = CALayer()
    private let selection = CAShapeLayer()
    private let handle = CAShapeLayer()
    private var leaf: CATransformLayer?
    private(set) var isTurning = false
    private var turningForward = true
    private var videos: [PhotoID: AVPlayerLayer] = [:]
    private var hovered: PhotoID?
    private var tracking: NSTrackingArea?
    private var drag: Drag?
    /// The photos VoiceOver finds on the pages showing, made when it first asks.
    private var spots: [AccessibleSpot]?
    /// The place VoiceOver was last told about.
    private var announcedState: Int?

    private enum Drag {
        case photo(id: PhotoID, page: Int, start: NSPoint, center: CGPoint, moved: Bool)
        case rotate(id: PhotoID, page: Int, center: CGPoint, startAngle: Double, startPointerAngle: Double)
        case page(forward: Bool, start: NSPoint, progress: CGFloat)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        desk.colors = [NSColor(srgbRed: 0.86, green: 0.83, blue: 0.79, alpha: 1).cgColor, NSColor(srgbRed: 0.72, green: 0.68, blue: 0.63, alpha: 1).cgColor]
        desk.type = .radial
        desk.startPoint = CGPoint(x: 0.5, y: 0.45)
        desk.endPoint = CGPoint(x: 1.25, y: 1.3)
        layer?.addSublayer(desk)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 2400
        book.sublayerTransform = perspective
        layer?.addSublayer(book)
        bookShadow.backgroundColor = NSColor.black.cgColor
        bookShadow.shadowColor = NSColor.black.cgColor
        bookShadow.shadowOpacity = 0.45
        bookShadow.shadowRadius = 22
        bookShadow.shadowOffset = CGSize(width: 0, height: 10)
        bookShadow.cornerRadius = 4
        book.addSublayer(bookShadow)
        for page in [leftPage, rightPage] {
            page.contentsGravity = .resize
            page.masksToBounds = true
            book.addSublayer(page)
        }
        leftPage.cornerRadius = 4
        leftPage.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        rightPage.cornerRadius = 4
        rightPage.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        selection.fillColor = nil
        selection.lineWidth = 2.5
        selection.isHidden = true
        handle.isHidden = true
        handle.lineWidth = 2
        book.addSublayer(selection)
        book.addSublayer(handle)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Photo book")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Next Page") { [weak self] in
                self?.next()
                return true
            },
            NSAccessibilityCustomAction(name: "Previous Page") { [weak self] in
                self?.previous()
                return true
            },
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        desk.colors = dark
            ? [NSColor(srgbRed: 0.2, green: 0.19, blue: 0.2, alpha: 1).cgColor, NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1).cgColor]
            : [NSColor(srgbRed: 0.88, green: 0.85, blue: 0.81, alpha: 1).cgColor, NSColor(srgbRed: 0.73, green: 0.69, blue: 0.64, alpha: 1).cgColor]
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selection.strokeColor = Theme.accent.cgColor
            handle.strokeColor = Theme.accent.cgColor
            handle.fillColor = NSColor.white.cgColor
        }
    }

    // MARK: Geometry

    /// The size of one page on screen.
    var pageSize: CGSize {
        let room = bounds.insetBy(dx: 44, dy: 34)
        let height = max(80, min(room.height, room.width / 2 * BookLayout.pageSize.height / BookLayout.pageSize.width))
        return CGSize(width: height * BookLayout.pageSize.width / BookLayout.pageSize.height, height: height)
    }

    /// Where the spine is.
    private var spine: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    func pageRect(left: Bool) -> CGRect {
        let size = pageSize
        return CGRect(x: left ? spine.x - size.width : spine.x, y: spine.y - size.height / 2, width: size.width, height: size.height)
    }

    /// How far the book slides so a closed cover sits in the middle.
    private func offset(for state: Int) -> CGFloat {
        guard let layout = delegate?.layout else { return 0 }
        if state == 0 { return -pageSize.width / 2 }
        if state == layout.stateCount - 1 { return pageSize.width / 2 }
        return 0
    }

    /// A point on a page (page coordinates) in the view.
    func viewPoint(_ point: CGPoint, onLeft: Bool) -> CGPoint {
        let rect = pageRect(left: onLeft)
        let scale = rect.width / BookLayout.pageSize.width
        return CGPoint(x: rect.minX + point.x * scale + offset(for: state), y: rect.minY + point.y * scale)
    }

    /// The page under a point in the view, and the point in that page's coordinates.
    func pagePoint(_ point: NSPoint) -> (page: Int, point: CGPoint, left: Bool)? {
        guard let layout = delegate?.layout else { return nil }
        let pages = layout.state(state)
        for (left, page) in [(true, pages.left), (false, pages.right)] {
            guard let page else { continue }
            let rect = pageRect(left: left).offsetBy(dx: offset(for: state), dy: 0)
            guard rect.contains(point) else { continue }
            let scale = BookLayout.pageSize.width / rect.width
            return (page, CGPoint(x: (point.x - rect.minX) * scale, y: (point.y - rect.minY) * scale), left)
        }
        return nil
    }

    // MARK: Showing pages

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        desk.frame = bounds
        book.frame = bounds
        CATransaction.commit()
        reload()
    }

    /// Shows the current place again, with fresh page pictures.
    func reload() {
        guard let delegate, !isTurning else { return }
        let layout = delegate.layout
        state = min(max(state, 0), layout.stateCount - 1)
        let pages = layout.state(state)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        book.transform = CATransform3DMakeTranslation(offset(for: state), 0, 0)
        leftPage.frame = pageRect(left: true)
        rightPage.frame = pageRect(left: false)
        leftPage.contents = pages.left.flatMap(delegate.pageImage)
        rightPage.contents = pages.right.flatMap(delegate.pageImage)
        leftPage.isHidden = pages.left == nil
        rightPage.isHidden = pages.right == nil
        bookShadow.frame = pages.left == nil ? pageRect(left: false) : (pages.right == nil ? pageRect(left: true) : pageRect(left: true).union(pageRect(left: false)))
        CATransaction.commit()
        updateSelection()
        refreshVideos()
        spots = nil
        if announcedState != state {
            announcedState = state
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// Redraws one page in place (after an edit or a photo arriving).
    func reloadPage(_ page: Int) {
        guard let delegate, !isTurning else { return }
        let pages = delegate.layout.state(state)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pages.left == page { leftPage.contents = delegate.pageImage(page) }
        if pages.right == page { rightPage.contents = delegate.pageImage(page) }
        CATransaction.commit()
        updateSelection()
    }

    func go(to newState: Int, animated: Bool = true) {
        guard let layout = delegate?.layout, newState != state, (0..<layout.stateCount).contains(newState) else { return }
        if animated, abs(newState - state) == 1 {
            turn(forward: newState > state)
        } else {
            state = newState
            select(nil)
            reload()
            delegate?.bookDidChangeState(state)
        }
    }

    func next() { turn(forward: true) }
    func previous() { turn(forward: false) }

    // MARK: VoiceOver

    /// Which pages are open: "Cover", "Pages 3–4 of 20".
    override func accessibilityValue() -> Any? { delegate?.bookPlace(state) }

    /// The photos on the open pages, each found where it lies; pressing one opens it.
    override func accessibilityChildren() -> [Any]? {
        if let spots { return spots }
        guard let layout = delegate?.layout, !isTurning else { return [] }
        let pages = layout.state(state)
        var made: [AccessibleSpot] = []
        for (left, page) in [(true, pages.left), (false, pages.right)] {
            guard let page else { continue }
            for placement in layout.pages[page].placements {
                let id = placement.id
                made.append(AccessibleSpot(in: self, role: .image, name: { [weak self] in self?.delegate?.bookDescription(of: id) ?? "Photo" },
                                           rect: { [weak self] in self?.viewFrame(of: placement, left: left) },
                                           press: { [weak self] in self?.delegate?.bookOpenPhoto(id) }))
            }
        }
        spots = made
        return made
    }

    /// Roughly where a photo lies on the open book, in the view.
    private func viewFrame(of placement: BookPlacement, left: Bool) -> NSRect? {
        guard let frame = delegate?.layout.settings.frame else { return nil }
        let size = placement.frameSize(frame)
        let scale = pageRect(left: left).width / BookLayout.pageSize.width
        let center = viewPoint(placement.center, onLeft: left)
        return NSRect(x: center.x - size.width * scale / 2, y: center.y - size.height * scale / 2,
                      width: size.width * scale, height: size.height * scale)
    }

    // MARK: Turning a page

    /// Turns one leaf, from wherever it is now (for a drag let go partway) to the end.
    func turn(forward: Bool, from progress: CGFloat = 0, duration: CFTimeInterval = 0.8) {
        guard let delegate, !isTurning || leaf != nil && progress > 0 else { return }
        let layout = delegate.layout
        let target = forward ? state + 1 : state - 1
        guard (0..<layout.stateCount).contains(target) else {
            NSSound.beep()
            return
        }
        // With Reduce Motion, the next pages fade in instead; a page being dragged still follows the pointer.
        if Motion.isReduced, leaf == nil {
            fade(to: target)
            return
        }
        if leaf == nil { beginTurn(forward: forward) }
        guard let leaf else { return }
        isTurning = true
        let start = forward ? -CGFloat.pi * progress : -CGFloat.pi * (1 - progress)
        let end: CGFloat = forward ? -.pi : 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finishTurn(to: target) }
        }
        let rotation = CABasicAnimation(keyPath: "transform")
        rotation.fromValue = CATransform3DMakeRotation(start, 0, 1, 0)
        rotation.toValue = CATransform3DMakeRotation(end, 0, 1, 0)
        let remaining = duration * Double(1 - progress)
        rotation.duration = max(0.15, remaining)
        rotation.timingFunction = CAMediaTimingFunction(name: progress > 0 ? .easeOut : .easeInEaseOut)
        leaf.transform = CATransform3DMakeRotation(end, 0, 1, 0)
        leaf.add(rotation, forKey: "turn")
        shade(leaf, duration: rotation.duration)
        // A closed book slides to the middle as it opens, and back as it closes.
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = book.presentation()?.transform ?? book.transform
        slide.toValue = CATransform3DMakeTranslation(offset(for: target), 0, 0)
        slide.duration = rotation.duration
        slide.timingFunction = rotation.timingFunction
        book.transform = CATransform3DMakeTranslation(offset(for: target), 0, 0)
        book.add(slide, forKey: "slide")
        CATransaction.commit()
    }

    /// Puts a leaf on the spine with the page turning over on its front and the next on its back, and shows what
    /// the leaf will uncover.
    private func beginTurn(forward: Bool) {
        guard let delegate else { return }
        let layout = delegate.layout
        let target = forward ? state + 1 : state - 1
        guard let pages = layout.leafTurningForward(from: forward ? state : target) else { return }
        select(nil)
        stopVideos()
        turningForward = forward
        let under = layout.state(target)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = pageRect(left: false)
        let leaf = CATransformLayer()
        leaf.anchorPoint = CGPoint(x: 0, y: 0.5)
        leaf.bounds = CGRect(origin: .zero, size: rect.size)
        leaf.position = CGPoint(x: rect.minX, y: rect.midY)
        let front = CALayer()
        front.frame = leaf.bounds
        front.contents = delegate.pageImage(pages.front)
        front.contentsGravity = .resize
        front.isDoubleSided = false
        let back = CALayer()
        back.frame = leaf.bounds
        back.contents = delegate.pageImage(pages.back)
        back.contentsGravity = .resize
        back.isDoubleSided = false
        back.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        for (side, start) in [(front, CGPoint(x: 0, y: 0.5)), (back, CGPoint(x: 1, y: 0.5))] {
            let gloom = CAGradientLayer()
            gloom.frame = side.bounds
            gloom.colors = [NSColor.black.withAlphaComponent(0.35).cgColor, NSColor.black.withAlphaComponent(0.05).cgColor]
            gloom.startPoint = start
            gloom.endPoint = CGPoint(x: 1 - start.x, y: 0.5)
            gloom.opacity = 0
            gloom.name = "gloom"
            side.addSublayer(gloom)
        }
        leaf.addSublayer(front)
        leaf.addSublayer(back)
        leaf.transform = CATransform3DMakeRotation(forward ? 0 : -.pi, 0, 1, 0)
        book.insertSublayer(leaf, below: selection)
        self.leaf = leaf
        // Under the leaf: going forward, the next spread's right page; going back, the earlier one's left page.
        if forward {
            rightPage.contents = under.right.flatMap(delegate.pageImage)
            rightPage.isHidden = under.right == nil
        } else {
            leftPage.contents = under.left.flatMap(delegate.pageImage)
            leftPage.isHidden = under.left == nil
        }
        CATransaction.commit()
    }

    /// Crossfades to another place in the book, for Reduce Motion.
    private func fade(to target: Int) {
        select(nil)
        stopVideos()
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.35
        layer?.add(fade, forKey: "fade")
        state = target
        reload()
        delegate?.bookDidChangeState(state)
    }

    /// Darkens the leaf's faces as it stands upright, as light falls across a curling page.
    private func shade(_ leaf: CALayer, duration: CFTimeInterval) {
        for side in leaf.sublayers ?? [] {
            guard let gloom = side.sublayers?.first(where: { $0.name == "gloom" }) else { continue }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0]
            fade.keyTimes = [0, 0.5, 1]
            fade.duration = duration
            gloom.add(fade, forKey: "gloom")
        }
    }

    private func finishTurn(to target: Int) {
        leaf?.removeFromSuperlayer()
        leaf = nil
        isTurning = false
        state = target
        reload()
        delegate?.bookDidChangeState(state)
    }

    /// Follows a page being dragged over: 0 lying flat where it started, 1 turned all the way.
    private func dragTurn(forward: Bool, progress: CGFloat) {
        guard let layout = delegate?.layout else { return }
        let target = forward ? state + 1 : state - 1
        guard (0..<layout.stateCount).contains(target) else { return }
        if leaf == nil {
            beginTurn(forward: forward)
            isTurning = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let angle = forward ? -CGFloat.pi * progress : -CGFloat.pi * (1 - progress)
        leaf?.transform = CATransform3DMakeRotation(angle, 0, 1, 0)
        CATransaction.commit()
    }

    #if DEBUG
    /// Holds a page partway through turning, for screenshots.
    func holdTurn(at progress: CGFloat) { dragTurn(forward: true, progress: progress) }
    #endif

    /// A drag let go: finish the turn past a third of the way, otherwise lay the page back.
    private func endDragTurn(forward: Bool, progress: CGFloat) {
        guard leaf != nil else { return }
        if progress > 0.33 {
            turn(forward: forward, from: progress)
        } else {
            // Back to where it was: a turn the other way, from what's left.
            let leaf = self.leaf!
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.leaf?.removeFromSuperlayer()
                    self.leaf = nil
                    self.isTurning = false
                    self.reload()
                }
            }
            let flat: CGFloat = forward ? 0 : -.pi
            let rotation = CABasicAnimation(keyPath: "transform")
            rotation.fromValue = leaf.presentation()?.transform ?? leaf.transform
            rotation.toValue = CATransform3DMakeRotation(flat, 0, 1, 0)
            rotation.duration = 0.25
            leaf.transform = CATransform3DMakeRotation(flat, 0, 1, 0)
            leaf.add(rotation, forKey: "settle")
            CATransaction.commit()
        }
    }

    // MARK: Picking and moving photos

    func select(_ id: PhotoID?) {
        guard selected != id else { return }
        selected = id
        updateSelection()
        delegate?.bookSelectionDidChange(id)
    }

    /// The selected photo's place: its page and whether that's on the left.
    private func selectedPlacement() -> (placement: BookPlacement, page: Int, left: Bool)? {
        guard let selected, let layout = delegate?.layout, let found = layout.find(selected) else { return nil }
        let pages = layout.state(state)
        guard found.page == pages.left || found.page == pages.right else { return nil }
        return (found.placement, found.page, found.page == pages.left)
    }

    private func updateSelection() {
        guard let (placement, _, left) = selectedPlacement(), let frame = delegate?.layout.settings.frame else {
            selection.isHidden = true
            handle.isHidden = true
            return
        }
        let corners = placement.corners(frame).map { viewPoint($0, onLeft: left) }
        let outline = CGMutablePath()
        outline.addLines(between: corners)
        outline.closeSubpath()
        let top = placement.frameRect(frame).minY
        let knobCenter = viewPoint(placement.page(CGPoint(x: 0, y: top - 28)), onLeft: left)
        let topMiddle = viewPoint(placement.page(CGPoint(x: 0, y: top)), onLeft: left)
        let knob = CGMutablePath()
        knob.move(to: topMiddle)
        knob.addLine(to: knobCenter)
        knob.addEllipse(in: CGRect(x: knobCenter.x - 8, y: knobCenter.y - 8, width: 16, height: 16))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let offset = offset(for: state)
        selection.frame = book.bounds.offsetBy(dx: -offset, dy: 0)
        handle.frame = selection.frame
        selection.path = outline
        handle.path = knob
        selection.isHidden = false
        handle.isHidden = false
        CATransaction.commit()
    }

    /// Whether a point is on the selected photo's turning handle.
    private func onHandle(_ point: NSPoint) -> Bool {
        guard let (placement, _, left) = selectedPlacement(), let frame = delegate?.layout.settings.frame else { return false }
        let knob = viewPoint(placement.page(CGPoint(x: 0, y: placement.frameRect(frame).minY - 28)), onLeft: left)
        return hypot(point.x - knob.x, point.y - knob.y) < 14
    }

    // MARK: Mouse and keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let delegate, !isTurning else { return }
        let layout = delegate.layout
        if onHandle(point), let (placement, page, _) = selectedPlacement() {
            let pagePoint = pagePoint(point)?.point ?? placement.center
            drag = .rotate(id: placement.id, page: page, center: placement.center, startAngle: placement.angle,
                           startPointerAngle: atan2(pagePoint.y - placement.center.y, pagePoint.x - placement.center.x))
            return
        }
        guard let hit = pagePoint(point) else {
            select(nil)
            return
        }
        if layout.pages[hit.page].kind == .photos, let placement = layout.placement(at: hit.point, onPage: hit.page) {
            if event.clickCount == 2 {
                delegate.bookOpenPhoto(placement.id)
                return
            }
            select(placement.id)
            drag = .photo(id: placement.id, page: hit.page, start: point, center: placement.center, moved: false)
            return
        }
        select(nil)
        // The paper: the right page turns forward, the left back.
        drag = .page(forward: !hit.left, start: point, progress: 0)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let current = drag else { return }
        let scale = BookLayout.pageSize.width / pageSize.width
        switch current {
        case let .photo(id, page, start, center, _):
            let moved = CGPoint(x: center.x + (point.x - start.x) * scale, y: center.y + (point.y - start.y) * scale)
            drag = .photo(id: id, page: page, start: start, center: center, moved: true)
            delegate?.bookPreview(id, center: BookLayout.clamp(moved), angle: nil)
            reloadPage(page)
        case let .rotate(id, page, center, startAngle, startPointerAngle):
            guard let pagePoint = pagePoint(point)?.point else { return }
            let pointer = atan2(pagePoint.y - center.y, pagePoint.x - center.x)
            var angle = startAngle + (pointer - startPointerAngle) * 180 / .pi
            if event.modifierFlags.contains(.shift) { angle = (angle / 15).rounded() * 15 }
            delegate?.bookPreview(id, center: nil, angle: Self.normalized(angle))
            reloadPage(page)
        case let .page(forward, start, _):
            let distance = forward ? start.x - point.x : point.x - start.x
            let progress = min(max(distance / (pageSize.width * 1.6), 0), 1)
            drag = .page(forward: forward, start: start, progress: progress)
            if progress > 0.02 { dragTurn(forward: forward, progress: progress) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { drag = nil }
        guard let current = drag else { return }
        let scale = BookLayout.pageSize.width / pageSize.width
        switch current {
        case let .photo(id, _, start, center, moved):
            guard moved else { return }
            let final = CGPoint(x: center.x + (point.x - start.x) * scale, y: center.y + (point.y - start.y) * scale)
            delegate?.bookCommit(id, center: BookLayout.clamp(final), angle: nil)
        case let .rotate(id, _, center, startAngle, startPointerAngle):
            guard let pagePoint = pagePoint(point)?.point else { return }
            var angle = startAngle + (atan2(pagePoint.y - center.y, pagePoint.x - center.x) - startPointerAngle) * 180 / .pi
            if event.modifierFlags.contains(.shift) { angle = (angle / 15).rounded() * 15 }
            delegate?.bookCommit(id, center: nil, angle: Self.normalized(angle))
        case let .page(forward, _, progress):
            if leaf != nil {
                endDragTurn(forward: forward, progress: progress)
            } else {
                turn(forward: forward)
            }
        }
    }

    static func normalized(_ angle: Double) -> Double {
        var angle = angle.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        return (angle * 10).rounded() / 10
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: previous()
        case 124: next()
        case 53: select(nil)
        default:
            super.keyDown(with: event)
        }
    }

    /// A two-finger swipe turns the page.
    private var swipe: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.phase == .ended else { return }
        if event.phase == .began { swipe = 0 }
        swipe += event.scrollingDeltaX
        if event.phase == .ended || (event.phase == [] && event.momentumPhase == []) {
            if swipe < -40 { next() } else if swipe > 40 { previous() }
            swipe = 0
        }
    }

    // MARK: Videos

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !isTurning, let delegate, let hit = pagePoint(point) else {
            hover(nil)
            return
        }
        let placement = delegate.layout.pages[hit.page].kind == .photos ? delegate.layout.placement(at: hit.point, onPage: hit.page) : nil
        hover(placement?.isVideo == true ? placement?.id : nil)
    }

    override func mouseExited(with event: NSEvent) { hover(nil) }

    /// Plays the video under the pointer (with sound, if that's on), and quiets or stops the one it left.
    func hover(_ id: PhotoID?) {
        guard id != hovered, let delegate else { return }
        if let old = hovered {
            if delegate.alwaysPlaysVideos {
                videos[old]?.player?.isMuted = true
            } else {
                stopVideo(old)
            }
        }
        hovered = id
        guard let id else { return }
        if let layer = videos[id] {
            layer.player?.isMuted = !delegate.playsVideoSound
            layer.player?.play()
        } else {
            startVideo(id, muted: !delegate.playsVideoSound)
        }
    }

    /// Starts every video on the open pages, quietly, when Settings asks for that.
    private func refreshVideos() {
        stopVideos()
        guard let delegate, delegate.alwaysPlaysVideos, !isTurning else { return }
        let pages = delegate.layout.state(state)
        for page in [pages.left, pages.right].compactMap({ $0 }) where delegate.layout.pages[page].kind == .photos {
            for placement in delegate.layout.pages[page].placements where placement.isVideo {
                startVideo(placement.id, muted: true)
            }
        }
    }

    var playingVideos: [PhotoID] { videos.compactMap { $0.value.player?.rate ?? 0 > 0 ? $0.key : nil } }

    private func startVideo(_ id: PhotoID, muted: Bool) {
        guard let delegate, let found = delegate.layout.find(id) else { return }
        let pages = delegate.layout.state(state)
        guard found.page == pages.left || found.page == pages.right else { return }
        let left = found.page == pages.left
        let frame = delegate.layout.settings.frame
        let placement = found.placement
        delegate.bookPlayer(for: id) { [weak self] player in
            guard let self, let player, self.videos[id] == nil, !self.isTurning else { return }
            let image = placement.imageRect(frame)
            let scale = self.pageSize.width / BookLayout.pageSize.width
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.bounds = CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale)
            let center = self.viewPoint(placement.page(CGPoint(x: image.midX, y: image.midY)), onLeft: left)
            layer.position = CGPoint(x: center.x - self.offset(for: self.state), y: center.y)
            layer.setAffineTransform(CGAffineTransform(rotationAngle: placement.angle * .pi / 180))
            layer.masksToBounds = true
            self.book.insertSublayer(layer, below: self.selection)
            self.videos[id] = layer
            player.isMuted = muted || SelfTestMode.isRunning
            player.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem,
                                                   queue: .main) { [weak player] _ in
                MainActor.assumeIsolated {
                    player?.seek(to: .zero)
                    player?.play()
                }
            }
            player.play()
        }
    }

    private func stopVideo(_ id: PhotoID) {
        videos[id]?.player?.pause()
        videos[id]?.removeFromSuperlayer()
        videos[id] = nil
    }

    func stopVideos() {
        for id in Array(videos.keys) { stopVideo(id) }
        hovered = nil
    }
}
