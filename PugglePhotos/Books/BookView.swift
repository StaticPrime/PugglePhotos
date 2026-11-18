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
    /// While a sticky note is moved, resized or turned: draw its page with it so.
    func bookPreviewSticky(_ id: PhotoID, _ sticky: BookSticky)
    /// When the move, resize or turn ends.
    func bookCommitSticky(_ id: PhotoID, _ sticky: BookSticky, actionName: String)
    /// Write a photo's note, from its sticky note or its back; `rect` is where it is in the view.
    func bookWriteNote(_ id: PhotoID, at rect: NSRect)
    /// The menu for a photo, or its sticky note.
    func bookMenu(for id: PhotoID, sticky: Bool) -> NSMenu?
    /// Which photo shows its back, and which is left off its page while it turns over above it.
    func bookSetTurnedOver(_ id: PhotoID?, hiding: PhotoID?)
    /// A photo alone, front or back, for turning it over above the page.
    func bookPhotoSide(_ id: PhotoID, back: Bool, scale: CGFloat) -> (image: CGImage, size: CGSize)?
    /// How much room writing takes on its page.
    func bookWritingSize(_ writing: BookWriting) -> CGSize
    /// The font writing is in on a page, and its ink's color there.
    func bookWritingLook(_ writing: BookWriting, onPage page: Int) -> (font: NSFont, color: NSColor)
    /// New writing starting at a point on a page, not kept until something's written; nil where nothing can be.
    func bookNewWriting(at point: CGPoint, onPage page: Int) -> BookWriting?
    /// While writing is moved, widened or turned: draw its page with it so. `editing` is left off its page while
    /// it's being written in place above it.
    func bookPreviewWriting(_ writing: BookWriting?, editing: UUID?)
    /// Keeps writing that changed; nothing written erases it.
    func bookCommitWriting(_ writing: BookWriting, actionName: String)
    func bookEraseWriting(_ id: UUID)
    /// The menus for writing, and for an added page.
    func bookWritingMenu(_ id: UUID) -> NSMenu?
    func bookPageMenu(_ page: Int) -> NSMenu?
    func bookPlayer(for id: PhotoID, completion: @escaping @MainActor (AVPlayer?) -> Void)
    var alwaysPlaysVideos: Bool { get }
    var playsVideoSound: Bool { get }
}

/// A photo book open on a desk: two pages side by side (or the closed cover), turned with a real-looking page turn.
/// Click the paper to turn a page, or drag it over; click a photo to pick it, then drag it or its round handle to
/// move or turn it, or click it again to turn it over and read its back. Sticky notes move, stretch and turn the
/// same way, and a double-click writes on one. Videos play while the pointer is over them.
final class BookView: NSView, NSTextViewDelegate {
    weak var delegate: BookViewDelegate?
    private(set) var state = 0

    /// What's picked: a photo, or a photo's sticky note.
    enum Pick: Equatable {
        case photo(PhotoID)
        case sticky(PhotoID)
        case writing(UUID)
    }

    /// The writing picked.
    var selectedWriting: UUID? {
        if case let .writing(id) = pick { return id }
        return nil
    }

    /// While on, a click on a page starts writing there; a click on writing writes on it.
    var isWriting = false {
        didSet {
            guard isWriting != oldValue else { return }
            if !isWriting { endEditing() }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The writing being written in place, above its page.
    private var editor: WritingTextView?
    private var editing: (writing: BookWriting, page: Int, isNew: Bool)?
    /// The writing being written, if any.
    var editingWriting: UUID? { editing?.writing.id }

    private(set) var pick: Pick?
    /// The photo picked, if it's a photo.
    var selected: PhotoID? {
        if case let .photo(id) = pick { return id }
        return nil
    }
    /// The photo whose sticky note is picked.
    var selectedSticky: PhotoID? {
        if case let .sticky(id) = pick { return id }
        return nil
    }
    /// The photo turned over to show its back, if any.
    private(set) var turnedOver: PhotoID?
    /// The photo turning over above the page, while it turns.
    private var turnLayer: CALayer?
    private let stickyHandle = CAShapeLayer()
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
        /// `turns`: the photo was already picked, so a click without moving turns it over.
        case photo(id: PhotoID, page: Int, start: NSPoint, center: CGPoint, moved: Bool, turns: Bool)
        case rotate(id: PhotoID, page: Int, center: CGPoint, startAngle: Double, startPointerAngle: Double)
        /// `clickTurns`: nothing was picked, so a click (not just a drag) turns the page.
        case page(forward: Bool, start: NSPoint, progress: CGFloat, clickTurns: Bool)
        case sticky(id: PhotoID, page: Int, start: NSPoint, sticky: BookSticky, moved: Bool)
        case stretchSticky(id: PhotoID, page: Int, sticky: BookSticky)
        case turnSticky(id: PhotoID, page: Int, sticky: BookSticky, startPointerAngle: Double)
        case writing(page: Int, start: NSPoint, writing: BookWriting, moved: Bool)
        case widenWriting(page: Int, writing: BookWriting)
        case turnWriting(page: Int, writing: BookWriting, startPointerAngle: Double)
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
        for layer in [handle, stickyHandle] {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 2
            layer.shadowOffset = CGSize(width: 0, height: 1)
        }
        book.addSublayer(selection)
        book.addSublayer(handle)
        stickyHandle.isHidden = true
        stickyHandle.lineWidth = 2
        book.addSublayer(stickyHandle)
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

    /// The self-test clicks while another app may be in front, so its clicks count even then.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { SelfTestMode.isRunning || super.acceptsFirstMouse(for: event) }

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
            stickyHandle.strokeColor = Theme.accent.cgColor
            stickyHandle.fillColor = NSColor.white.cgColor
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

    /// A point in the view in a page's coordinates, even off the page: for handles dragged past its edge.
    func pageCoordinates(_ point: NSPoint, onPage page: Int) -> CGPoint {
        let rect = pageRect(left: delegate?.layout.state(state).left == page)
        let scale = BookLayout.pageSize.width / rect.width
        return CGPoint(x: (point.x - offset(for: state) - rect.minX) * scale, y: (point.y - rect.minY) * scale)
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
        endEditing()
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
        endEditing()
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

    func select(_ id: PhotoID?) { pick(id.map(Pick.photo)) }

    func pick(_ new: Pick?) {
        guard pick != new else { return }
        pick = new
        updateSelection()
        delegate?.bookSelectionDidChange(selected)
    }

    /// The selected photo's place: its page and whether that's on the left.
    private func selectedPlacement() -> (placement: BookPlacement, page: Int, left: Bool)? {
        guard let selected, let layout = delegate?.layout, let found = layout.find(selected) else { return nil }
        let pages = layout.state(state)
        guard found.page == pages.left || found.page == pages.right else { return nil }
        return (found.placement, found.page, found.page == pages.left)
    }

    /// The picked sticky note's photo and where it is.
    private func stickyPlacement() -> (placement: BookPlacement, page: Int, left: Bool)? {
        guard let id = selectedSticky, let layout = delegate?.layout, let found = layout.find(id), found.placement.hasSticky,
              id != turnedOver else { return nil }
        let pages = layout.state(state)
        guard found.page == pages.left || found.page == pages.right else { return nil }
        return (found.placement, found.page, found.page == pages.left)
    }

    /// Where a sticky note's two handles are: the corner that stretches it, and the knob that turns it.
    private func stickyHandles(_ placement: BookPlacement, left: Bool) -> (stretch: CGPoint, turn: CGPoint, top: CGPoint) {
        let rect = placement.sticky.rect
        let knob = knob(from: placement.stickyPage(CGPoint(x: 0, y: rect.minY)), angle: placement.angle + placement.sticky.angle, left: left)
        return (viewPoint(placement.stickyPage(CGPoint(x: rect.maxX, y: rect.maxY)), onLeft: left), knob.turn, knob.top)
    }

    // MARK: Handles

    /// How far a turning knob stands off the edge of what it turns, on screen, however big the book is drawn.
    private static let knobReach: CGFloat = 26
    private static let knobRadius: CGFloat = 9

    /// A turning knob standing off a point on an edge (in page coordinates), away from the middle of what it turns
    /// along its lean: where its stalk starts, and where the knob is.
    private func knob(from edge: CGPoint, angle: Double, left: Bool) -> (top: CGPoint, turn: CGPoint) {
        let start = viewPoint(edge, onLeft: left)
        let radians = angle * .pi / 180
        return (start, CGPoint(x: start.x + sin(radians) * Self.knobReach, y: start.y - cos(radians) * Self.knobReach))
    }

    /// Whether a point is on a knob: on the knob itself, generously, or along the outer part of its stalk.
    private static func isOn(_ knob: (top: CGPoint, turn: CGPoint), _ point: NSPoint) -> Bool {
        if hypot(point.x - knob.turn.x, point.y - knob.turn.y) < knobRadius + 9 { return true }
        let dx = knob.turn.x - knob.top.x, dy = knob.turn.y - knob.top.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return false }
        let along = ((point.x - knob.top.x) * dx + (point.y - knob.top.y) * dy) / length
        guard along > 0.25, along <= 1 else { return false }
        return hypot(point.x - (knob.top.x + along * dx), point.y - (knob.top.y + along * dy)) < 9
    }

    /// A knob drawn: its stalk and its circle.
    private static func knobPath(_ knob: (top: CGPoint, turn: CGPoint)) -> CGMutablePath {
        let path = CGMutablePath()
        let dx = knob.turn.x - knob.top.x, dy = knob.turn.y - knob.top.y
        let length = max(hypot(dx, dy), 1)
        path.move(to: knob.top)
        path.addLine(to: CGPoint(x: knob.turn.x - dx / length * knobRadius, y: knob.turn.y - dy / length * knobRadius))
        path.addEllipse(in: CGRect(x: knob.turn.x - knobRadius, y: knob.turn.y - knobRadius, width: knobRadius * 2, height: knobRadius * 2))
        return path
    }

    /// The picked photo's knob.
    private func photoKnob() -> (top: CGPoint, turn: CGPoint)? {
        guard let (placement, _, left) = selectedPlacement(), let frame = delegate?.layout.settings.frame else { return nil }
        return knob(from: placement.page(CGPoint(x: 0, y: placement.frameRect(frame).minY)), angle: placement.angle, left: left)
    }

    #if DEBUG
    /// The picked thing's knob, for the self-test.
    var knobForTesting: (top: CGPoint, turn: CGPoint)? {
        if let knob = photoKnob() { return knob }
        if let (placement, _, left) = stickyPlacement() {
            let handles = stickyHandles(placement, left: left)
            return (handles.top, handles.turn)
        }
        return nil
    }
    #endif

    /// Whether a point is on any handle of what's picked, to show the pointer can take hold there.
    private func isOnHandle(_ point: NSPoint) -> Bool {
        if let knob = photoKnob(), Self.isOn(knob, point) { return true }
        if let (placement, _, left) = stickyPlacement() {
            let handles = stickyHandles(placement, left: left)
            if Self.isOn((handles.top, handles.turn), point) || hypot(point.x - handles.stretch.x, point.y - handles.stretch.y) < 16 { return true }
        }
        if let (writing, _, left) = writingPlace(), let size = delegate?.bookWritingSize(writing) {
            let handles = writingHandles(writing, size: size, left: left)
            if Self.isOn((handles.top, handles.turn), point) || hypot(point.x - handles.widen.x, point.y - handles.widen.y) < 16 { return true }
        }
        return false
    }

    private func updateSelection() {
        stickyHandle.isHidden = true
        if let (writing, _, left) = writingPlace(), editing == nil, let size = delegate?.bookWritingSize(writing) {
            let rect = CGRect(x: -size.width / 2 - 4, y: -size.height / 2 - 4, width: size.width + 8, height: size.height + 8)
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                           CGPoint(x: rect.minX, y: rect.maxY)].map { viewPoint(writing.page($0), onLeft: left) }
            let outline = CGMutablePath()
            outline.addLines(between: corners)
            outline.closeSubpath()
            let handles = writingHandles(writing, size: size, left: left)
            let knob = Self.knobPath((handles.top, handles.turn))
            let widen = CGMutablePath()
            widen.addRoundedRect(in: CGRect(x: handles.widen.x - 5, y: handles.widen.y - 12, width: 10, height: 24), cornerWidth: 4, cornerHeight: 4)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let offset = offset(for: state)
            for layer in [selection, handle, stickyHandle] { layer.frame = book.bounds.offsetBy(dx: -offset, dy: 0) }
            selection.path = outline
            selection.lineDashPattern = [5, 4]
            handle.path = knob
            stickyHandle.path = widen
            selection.isHidden = false
            handle.isHidden = false
            stickyHandle.isHidden = false
            CATransaction.commit()
            return
        }
        selection.lineDashPattern = nil
        if let (placement, _, left) = stickyPlacement() {
            let corners = placement.stickyCorners().map { viewPoint($0, onLeft: left) }
            let outline = CGMutablePath()
            outline.addLines(between: corners)
            outline.closeSubpath()
            let handles = stickyHandles(placement, left: left)
            let knob = Self.knobPath((handles.top, handles.turn))
            let corner = CGMutablePath()
            corner.addRoundedRect(in: CGRect(x: handles.stretch.x - 7, y: handles.stretch.y - 7, width: 14, height: 14), cornerWidth: 3, cornerHeight: 3)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let offset = offset(for: state)
            for layer in [selection, handle, stickyHandle] { layer.frame = book.bounds.offsetBy(dx: -offset, dy: 0) }
            selection.path = outline
            handle.path = knob
            stickyHandle.path = corner
            selection.isHidden = false
            handle.isHidden = false
            stickyHandle.isHidden = false
            CATransaction.commit()
            return
        }
        guard let (placement, _, left) = selectedPlacement(), let frame = delegate?.layout.settings.frame else {
            selection.isHidden = true
            handle.isHidden = true
            return
        }
        let corners = placement.corners(frame).map { viewPoint($0, onLeft: left) }
        let outline = CGMutablePath()
        outline.addLines(between: corners)
        outline.closeSubpath()
        let knob = Self.knobPath(knob(from: placement.page(CGPoint(x: 0, y: placement.frameRect(frame).minY)), angle: placement.angle, left: left))
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
        photoKnob().map { Self.isOn($0, point) } ?? false
    }

    // MARK: Sticky notes

    /// A sticky note moved by a distance on the page: the move turned into its photo's own coordinates.
    static func moved(_ sticky: BookSticky, by delta: CGPoint, photoAngle: Double) -> BookSticky {
        let radians = -photoAngle * .pi / 180
        var moved = sticky
        moved.center = CGPoint(x: sticky.center.x + delta.x * cos(radians) - delta.y * sin(radians),
                               y: sticky.center.y + delta.x * sin(radians) + delta.y * cos(radians))
        return moved
    }

    /// A sticky note stretched by its bottom right corner to a point on the page, its top left corner staying put.
    static func stretched(_ sticky: BookSticky, to point: CGPoint, on placement: BookPlacement) -> BookSticky {
        var before = placement
        before.sticky = sticky
        let local = before.stickyLocal(point)
        let width = max(BookSticky.smallest.width, local.x + sticky.size.width / 2)
        let height = max(BookSticky.smallest.height, local.y + sticky.size.height / 2)
        // The middle moves by half the growth, along the note's own lean.
        let shift = CGPoint(x: (width - sticky.size.width) / 2, y: (height - sticky.size.height) / 2)
        let radians = sticky.angle * .pi / 180
        var stretched = sticky
        stretched.size = CGSize(width: width.rounded(), height: height.rounded())
        stretched.center = CGPoint(x: sticky.center.x + shift.x * cos(radians) - shift.y * sin(radians),
                                   y: sticky.center.y + shift.x * sin(radians) + shift.y * cos(radians))
        return stretched
    }

    /// A sticky note's lean, turned by its knob: Shift turns it in steps of 15°.
    static func turned(_ sticky: BookSticky, on placement: BookPlacement, pointer: CGPoint, startPointerAngle: Double, snapping: Bool) -> Double {
        var before = placement
        before.sticky = sticky
        let middle = before.stickyPage(.zero)
        var angle = sticky.angle + (atan2(pointer.y - middle.y, pointer.x - middle.x) - startPointerAngle) * 180 / .pi
        if snapping { angle = (angle / 15).rounded() * 15 }
        return normalized(angle)
    }

    /// The smallest rectangle in the view around some page points.
    private func viewRect(of points: [CGPoint], left: Bool) -> NSRect {
        let view = points.map { viewPoint($0, onLeft: left) }
        let xs = view.map(\.x), ys = view.map(\.y)
        return NSRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// Where a photo is in the view, for a popover beside it.
    func rect(of id: PhotoID) -> NSRect? {
        guard let layout = delegate?.layout, let found = layout.find(id) else { return nil }
        let pages = layout.state(state)
        guard found.page == pages.left || found.page == pages.right else { return nil }
        return viewRect(of: found.placement.corners(layout.settings.frame), left: found.page == pages.left)
    }

    // MARK: Turning a photo over

    /// Turns a photo over to show its back, or back again, turning it in depth above its page (or with Reduce
    /// Motion, at once). Only one photo shows its back at a time.
    func turnOver(_ id: PhotoID) {
        guard let delegate, turnLayer == nil, let found = delegate.layout.find(id) else { return }
        let pages = delegate.layout.state(state)
        guard found.page == pages.left || found.page == pages.right else { return }
        let over = turnedOver != id
        if over, turnedOver != nil { setTurnedOver(nil) }
        let page = found.page, left = found.page == pages.left
        let placement = found.placement
        let scale = pageRect(left: left).width / BookLayout.pageSize.width
        let pixels = scale * (window?.backingScaleFactor ?? 2)
        guard !Motion.isReduced, window != nil, let front = delegate.bookPhotoSide(id, back: false, scale: pixels),
              let back = delegate.bookPhotoSide(id, back: true, scale: pixels) else {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            layer?.add(fade, forKey: "turnOver")
            setTurnedOver(over ? id : nil)
            return
        }
        let size = CGSize(width: front.size.width * scale, height: front.size.height * scale)
        let container = CALayer()
        container.bounds = CGRect(origin: .zero, size: size)
        let center = viewPoint(placement.center, onLeft: left)
        container.position = CGPoint(x: center.x - offset(for: state), y: center.y)
        container.setAffineTransform(CGAffineTransform(rotationAngle: placement.angle * .pi / 180))
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / max(size.width * 3, 300)
        container.sublayerTransform = perspective
        let card = CATransformLayer()
        card.bounds = container.bounds
        card.position = CGPoint(x: size.width / 2, y: size.height / 2)
        for (image, isBack) in [(front.image, false), (back.image, true)] {
            let side = CALayer()
            side.contents = image
            side.bounds = container.bounds
            side.position = card.position
            side.isDoubleSided = false
            if isBack { side.transform = CATransform3DMakeRotation(.pi, 0, 1, 0) }
            card.addSublayer(side)
        }
        container.addSublayer(card)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        book.insertSublayer(container, below: selection)
        card.transform = over ? CATransform3DIdentity : CATransform3DMakeRotation(.pi, 0, 1, 0)
        selection.isHidden = true
        handle.isHidden = true
        stickyHandle.isHidden = true
        CATransaction.commit()
        turnLayer = container
        // The page without the photo while it turns above it.
        delegate.bookSetTurnedOver(turnedOver, hiding: id)
        reloadPage(page)
        stopVideos()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setTurnedOver(over ? id : nil)
                self.turnLayer?.removeFromSuperlayer()
                self.turnLayer = nil
                self.updateSelection()
            }
        }
        let turn = CABasicAnimation(keyPath: "transform")
        turn.fromValue = card.transform
        turn.toValue = over ? CATransform3DMakeRotation(.pi, 0, 1, 0) : CATransform3DIdentity
        turn.duration = 0.55
        turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        card.transform = turn.toValue as! CATransform3D
        card.add(turn, forKey: "turn")
        CATransaction.commit()
    }

    /// Shows a photo's back (or no photo's), redrawing the pages it changes.
    func setTurnedOver(_ id: PhotoID?) {
        let changed = [turnedOver, id].compactMap { $0 }
        turnedOver = id
        delegate?.bookSetTurnedOver(id, hiding: nil)
        guard let layout = delegate?.layout else { return }
        for photo in Set(changed) { if let page = layout.find(photo)?.page { reloadPage(page) } }
        updateSelection()
        spots = nil
    }

    /// The turned-over photo goes back when its page is turned.
    func forgetTurnedOver() {
        turnedOver = nil
        turnLayer?.removeFromSuperlayer()
        turnLayer = nil
        delegate?.bookSetTurnedOver(nil, hiding: nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let delegate, !isTurning, let hit = pagePoint(point) else { return nil }
        if let writing = writing(at: hit.point, onPage: hit.page) {
            pick(.writing(writing.id))
            return delegate.bookWritingMenu(writing.id)
        }
        guard delegate.layout.pages[hit.page].kind == .photos else { return delegate.bookPageMenu(hit.page) }
        if let placement = delegate.layout.sticky(at: hit.point, onPage: hit.page), placement.id != turnedOver {
            pick(.sticky(placement.id))
            return delegate.bookMenu(for: placement.id, sticky: true)
        }
        if let placement = delegate.layout.placement(at: hit.point, onPage: hit.page) {
            select(placement.id)
            return delegate.bookMenu(for: placement.id, sticky: false)
        }
        return delegate.bookPageMenu(hit.page)
    }

    // MARK: Writing on pages

    override func resetCursorRects() {
        if isWriting { addCursorRect(bounds, cursor: .iBeam) }
    }

    /// The writing on a page under a point, the topmost first.
    func writing(at point: CGPoint, onPage page: Int) -> BookWriting? {
        guard let delegate, delegate.layout.pages.indices.contains(page) else { return nil }
        return delegate.layout.pages[page].writings.reversed().first { writing in
            let size = delegate.bookWritingSize(writing)
            return CGRect(x: -size.width / 2 - 6, y: -size.height / 2 - 6, width: size.width + 12, height: size.height + 12)
                .contains(writing.local(point))
        }
    }

    /// The picked writing, its page, and whether that's the left one; nil unless it's on the open pages.
    private func writingPlace() -> (writing: BookWriting, page: Int, left: Bool)? {
        guard let id = selectedWriting, let layout = delegate?.layout else { return nil }
        let pages = layout.state(state)
        for page in [pages.left, pages.right].compactMap({ $0 }) {
            if let writing = layout.pages[page].writings.first(where: { $0.id == id }) { return (writing, page, page == pages.left) }
        }
        return nil
    }

    /// Where writing's handles are: the bar on its right side, and the knob above it.
    private func writingHandles(_ writing: BookWriting, size: CGSize, left: Bool) -> (widen: CGPoint, turn: CGPoint, top: CGPoint) {
        let knob = knob(from: writing.page(CGPoint(x: 0, y: -size.height / 2 - 4)), angle: writing.angle, left: left)
        return (viewPoint(writing.page(CGPoint(x: size.width / 2 + 4, y: 0)), onLeft: left), knob.turn, knob.top)
    }

    static func moved(_ writing: BookWriting, by delta: CGPoint) -> BookWriting {
        var moved = writing
        moved.center = CGPoint(x: writing.center.x + delta.x, y: writing.center.y + delta.y)
        return moved
    }

    /// Writing whose lines run as far as a point on the page, its left side staying put.
    static func widened(_ writing: BookWriting, to point: CGPoint) -> BookWriting {
        let local = writing.local(point)
        let width = min(max(local.x + writing.width / 2, BookWriting.widths.lowerBound), BookWriting.widths.upperBound).rounded()
        var widened = writing
        widened.width = width
        let shift = (width - writing.width) / 2
        let radians = writing.angle * .pi / 180
        widened.center = CGPoint(x: writing.center.x + shift * cos(radians), y: writing.center.y + shift * sin(radians))
        return widened
    }

    static func turned(_ writing: BookWriting, pointer: CGPoint, startPointerAngle: Double, snapping: Bool) -> BookWriting {
        var angle = writing.angle + (atan2(pointer.y - writing.center.y, pointer.x - writing.center.x) - startPointerAngle) * 180 / .pi
        if snapping { angle = (angle / 15).rounded() * 15 }
        var turned = writing
        turned.angle = normalized(angle)
        return turned
    }

    /// Writes in place above the page, in the book's handwriting at the page's scale: straight while it's written,
    /// at its angle again once it's done. The page leaves it off meanwhile.
    func beginEditing(_ writing: BookWriting, onPage page: Int, isNew: Bool) {
        endEditing()
        guard let delegate, delegate.layout.pages.indices.contains(page) else { return }
        let left = delegate.layout.state(state).left == page
        let scale = pageRect(left: left).width / BookLayout.pageSize.width
        let look = delegate.bookWritingLook(writing, onPage: page)
        let size = delegate.bookWritingSize(writing)
        let font = NSFont(descriptor: look.font.fontDescriptor, size: look.font.pointSize * scale) ?? look.font
        let origin = viewPoint(CGPoint(x: writing.center.x - size.width / 2, y: writing.center.y - size.height / 2), onLeft: left)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textView = WritingTextView(frame: NSRect(x: origin.x, y: origin.y, width: size.width * scale, height: max(size.height * scale, lineHeight)))
        textView.font = font
        textView.textColor = look.color
        textView.insertionPointColor = look.color
        textView.typingAttributes = [.font: font, .foregroundColor: look.color]
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: size.width * scale, height: lineHeight)
        textView.maxSize = NSSize(width: size.width * scale, height: 10_000)
        textView.string = writing.text
        textView.delegate = self
        textView.onDone = { [weak self] in self?.endEditing() }
        textView.setAccessibilityLabel("Writing on the page")
        addSubview(textView)
        editor = textView
        editing = (writing, page, isNew)
        delegate.bookPreviewWriting(nil, editing: writing.id)
        reloadPage(page)
        updateSelection()
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (writing.text as NSString).length, length: 0))
    }

    /// Finishes the writing written in place: keeps it (where it was begun, however much it grew), or with
    /// nothing written, erases it.
    func endEditing() {
        guard let textView = editor, let draft = editing, let delegate else { return }
        editor = nil
        editing = nil
        var writing = draft.writing
        writing.text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        textView.removeFromSuperview()
        // Its top stays where it was while it was written; the middle moves by half of any growth, along its lean.
        let grown = delegate.bookWritingSize(writing).height - delegate.bookWritingSize(draft.writing).height
        let radians = writing.angle * .pi / 180
        writing.center = CGPoint(x: writing.center.x - grown / 2 * sin(radians), y: writing.center.y + grown / 2 * cos(radians))
        delegate.bookPreviewWriting(nil, editing: nil)
        if writing.text.isEmpty {
            if draft.isNew { reloadPage(draft.page) } else { delegate.bookEraseWriting(writing.id) }
        } else if draft.isNew || writing.text != draft.writing.text {
            delegate.bookCommitWriting(writing, actionName: draft.isNew ? "Write on Page" : "Change Writing")
            pick(.writing(writing.id))
        } else {
            reloadPage(draft.page)
            pick(.writing(writing.id))
        }
        if window?.firstResponder == nil || window?.firstResponder === textView { window?.makeFirstResponder(self) }
        updateSelection()
    }

    func textDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSTextView) === editor { endEditing() }
    }

    // MARK: Mouse and keys

    override func mouseDown(with event: NSEvent) {
        // A click anywhere else finishes the writing being written.
        if editor != nil { endEditing() }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let delegate, !isTurning, turnLayer == nil else { return }
        let layout = delegate.layout
        // Picked writing's handles: the knob turns it, the bar on its side changes how wide its lines run.
        if let (writing, page, left) = writingPlace() {
            let handles = writingHandles(writing, size: delegate.bookWritingSize(writing), left: left)
            if hypot(point.x - handles.widen.x, point.y - handles.widen.y) < 16 {
                drag = .widenWriting(page: page, writing: writing)
                return
            }
            if Self.isOn((handles.top, handles.turn), point) {
                let pagePoint = pageCoordinates(point, onPage: page)
                drag = .turnWriting(page: page, writing: writing,
                                    startPointerAngle: atan2(pagePoint.y - writing.center.y, pagePoint.x - writing.center.x))
                return
            }
        }
        // A picked sticky note's handles: the corner stretches it, the knob turns it.
        if let (placement, page, left) = stickyPlacement() {
            let handles = stickyHandles(placement, left: left)
            if hypot(point.x - handles.stretch.x, point.y - handles.stretch.y) < 16 {
                drag = .stretchSticky(id: placement.id, page: page, sticky: placement.sticky)
                return
            }
            if Self.isOn((handles.top, handles.turn), point) {
                let middle = placement.stickyPage(.zero)
                let pagePoint = pagePoint(point)?.point ?? middle
                drag = .turnSticky(id: placement.id, page: page, sticky: placement.sticky,
                                   startPointerAngle: atan2(pagePoint.y - middle.y, pagePoint.x - middle.x))
                return
            }
        }
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
        // Writing lies over everything on the page.
        if let writing = writing(at: hit.point, onPage: hit.page) {
            if isWriting || event.clickCount == 2 {
                beginEditing(writing, onPage: hit.page, isNew: false)
                return
            }
            pick(.writing(writing.id))
            drag = .writing(page: hit.page, start: point, writing: writing, moved: false)
            return
        }
        // While writing: a click anywhere on a page starts writing there.
        if isWriting {
            pick(nil)
            if let new = delegate.bookNewWriting(at: hit.point, onPage: hit.page) { beginEditing(new, onPage: hit.page, isNew: true) }
            return
        }
        // Sticky notes lie over the photos.
        if layout.pages[hit.page].kind == .photos, let placement = layout.sticky(at: hit.point, onPage: hit.page), placement.id != turnedOver {
            if event.clickCount == 2 {
                delegate.bookWriteNote(placement.id, at: viewRect(of: placement.stickyCorners(), left: hit.left))
                return
            }
            pick(.sticky(placement.id))
            drag = .sticky(id: placement.id, page: hit.page, start: point, sticky: placement.sticky, moved: false)
            return
        }
        if layout.pages[hit.page].kind == .photos, let placement = layout.placement(at: hit.point, onPage: hit.page) {
            if event.clickCount == 2 {
                delegate.bookOpenPhoto(placement.id)
                return
            }
            // The first click picks a photo; a click on the photo picked turns it over.
            let turns = selected == placement.id
            select(placement.id)
            drag = .photo(id: placement.id, page: hit.page, start: point, center: placement.center, moved: false, turns: turns)
            return
        }
        // The paper: the right page turns forward, the left back. A click on it while something's picked only lets
        // that go; dragging the paper over still turns the page.
        let hadPick = pick != nil
        pick(nil)
        drag = .page(forward: !hit.left, start: point, progress: 0, clickTurns: !hadPick)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let current = drag else { return }
        let scale = BookLayout.pageSize.width / pageSize.width
        switch current {
        case let .photo(id, page, start, center, moved, turns):
            guard moved || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            let to = CGPoint(x: center.x + (point.x - start.x) * scale, y: center.y + (point.y - start.y) * scale)
            drag = .photo(id: id, page: page, start: start, center: center, moved: true, turns: turns)
            if turnedOver == id { setTurnedOver(nil) }
            delegate?.bookPreview(id, center: BookLayout.clamp(to), angle: nil)
            reloadPage(page)
        case let .writing(page, start, writing, moved):
            guard moved || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            drag = .writing(page: page, start: start, writing: writing, moved: true)
            delegate?.bookPreviewWriting(Self.moved(writing, by: CGPoint(x: (point.x - start.x) * scale, y: (point.y - start.y) * scale)), editing: nil)
            reloadPage(page)
            updateSelection()
        case let .widenWriting(page, writing):
            delegate?.bookPreviewWriting(Self.widened(writing, to: pageCoordinates(point, onPage: page)), editing: nil)
            reloadPage(page)
            updateSelection()
        case let .turnWriting(page, writing, startPointerAngle):
            delegate?.bookPreviewWriting(Self.turned(writing, pointer: pageCoordinates(point, onPage: page), startPointerAngle: startPointerAngle,
                                                     snapping: event.modifierFlags.contains(.shift)), editing: nil)
            reloadPage(page)
            updateSelection()
        case let .sticky(id, page, start, sticky, moved):
            guard moved || hypot(point.x - start.x, point.y - start.y) > 3, let placement = delegate?.layout.find(id)?.placement else { return }
            drag = .sticky(id: id, page: page, start: start, sticky: sticky, moved: true)
            delegate?.bookPreviewSticky(id, Self.moved(sticky, by: CGPoint(x: (point.x - start.x) * scale, y: (point.y - start.y) * scale),
                                                       photoAngle: placement.angle))
            reloadPage(page)
            updateSelection()
        case let .stretchSticky(id, page, sticky):
            guard let placement = delegate?.layout.find(id)?.placement else { return }
            delegate?.bookPreviewSticky(id, Self.stretched(sticky, to: pageCoordinates(point, onPage: page), on: placement))
            reloadPage(page)
            updateSelection()
        case let .turnSticky(id, page, sticky, startPointerAngle):
            guard let placement = delegate?.layout.find(id)?.placement else { return }
            var turned = sticky
            turned.angle = Self.turned(sticky, on: placement, pointer: pageCoordinates(point, onPage: page), startPointerAngle: startPointerAngle,
                                       snapping: event.modifierFlags.contains(.shift))
            delegate?.bookPreviewSticky(id, turned)
            reloadPage(page)
            updateSelection()
        case let .rotate(id, page, center, startAngle, startPointerAngle):
            let pagePoint = pageCoordinates(point, onPage: page)
            let pointer = atan2(pagePoint.y - center.y, pagePoint.x - center.x)
            var angle = startAngle + (pointer - startPointerAngle) * 180 / .pi
            if event.modifierFlags.contains(.shift) { angle = (angle / 15).rounded() * 15 }
            delegate?.bookPreview(id, center: nil, angle: Self.normalized(angle))
            reloadPage(page)
        case let .page(forward, start, _, clickTurns):
            let distance = forward ? start.x - point.x : point.x - start.x
            let progress = min(max(distance / (pageSize.width * 1.6), 0), 1)
            drag = .page(forward: forward, start: start, progress: progress, clickTurns: clickTurns)
            if progress > 0.02 { dragTurn(forward: forward, progress: progress) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { drag = nil }
        guard let current = drag else { return }
        let scale = BookLayout.pageSize.width / pageSize.width
        switch current {
        case let .photo(id, _, start, center, moved, turns):
            guard moved else {
                if turns { turnOver(id) }
                return
            }
            let final = CGPoint(x: center.x + (point.x - start.x) * scale, y: center.y + (point.y - start.y) * scale)
            delegate?.bookCommit(id, center: BookLayout.clamp(final), angle: nil)
        case let .writing(_, start, writing, moved):
            guard moved else { return }
            delegate?.bookCommitWriting(Self.moved(writing, by: CGPoint(x: (point.x - start.x) * scale, y: (point.y - start.y) * scale)),
                                        actionName: "Move Writing")
        case let .widenWriting(page, writing):
            delegate?.bookCommitWriting(Self.widened(writing, to: pageCoordinates(point, onPage: page)), actionName: "Change Writing Width")
        case let .turnWriting(page, writing, startPointerAngle):
            delegate?.bookCommitWriting(Self.turned(writing, pointer: pageCoordinates(point, onPage: page), startPointerAngle: startPointerAngle,
                                                    snapping: event.modifierFlags.contains(.shift)), actionName: "Turn Writing")
        case let .sticky(id, _, start, sticky, moved):
            guard moved, let placement = delegate?.layout.find(id)?.placement else { return }
            delegate?.bookCommitSticky(id, Self.moved(sticky, by: CGPoint(x: (point.x - start.x) * scale, y: (point.y - start.y) * scale),
                                                      photoAngle: placement.angle), actionName: "Move Sticky Note")
        case let .stretchSticky(id, page, sticky):
            guard let placement = delegate?.layout.find(id)?.placement else { return }
            delegate?.bookCommitSticky(id, Self.stretched(sticky, to: pageCoordinates(point, onPage: page), on: placement),
                                       actionName: "Resize Sticky Note")
        case let .turnSticky(id, page, sticky, startPointerAngle):
            guard let placement = delegate?.layout.find(id)?.placement else { return }
            var turned = sticky
            turned.angle = Self.turned(sticky, on: placement, pointer: pageCoordinates(point, onPage: page), startPointerAngle: startPointerAngle,
                                       snapping: event.modifierFlags.contains(.shift))
            delegate?.bookCommitSticky(id, turned, actionName: "Turn Sticky Note")
        case let .rotate(id, page, center, startAngle, startPointerAngle):
            let pagePoint = pageCoordinates(point, onPage: page)
            var angle = startAngle + (atan2(pagePoint.y - center.y, pagePoint.x - center.x) - startPointerAngle) * 180 / .pi
            if event.modifierFlags.contains(.shift) { angle = (angle / 15).rounded() * 15 }
            delegate?.bookCommit(id, center: nil, angle: Self.normalized(angle))
        case let .page(forward, _, progress, clickTurns):
            if leaf != nil {
                endDragTurn(forward: forward, progress: progress)
            } else if clickTurns {
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
        case 53:
            if turnedOver != nil { turnOver(turnedOver!) } else if isWriting { isWriting = false; delegate?.bookSelectionDidChange(selected) } else { pick(nil) }
        case 51, 117:
            if let id = selectedWriting {
                pick(nil)
                delegate?.bookEraseWriting(id)
            } else {
                super.keyDown(with: event)
            }
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
        // The pointer shows when it's over a handle it can take hold of.
        if !isWriting {
            if isOnHandle(point) { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
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

/// The writing written in place on a page: Esc or ⌘Return finishes it, as does a click anywhere else.
final class WritingTextView: NSTextView {
    var onDone: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onDone?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.contains(.command) {
            onDone?()
            return
        }
        super.keyDown(with: event)
    }
}
