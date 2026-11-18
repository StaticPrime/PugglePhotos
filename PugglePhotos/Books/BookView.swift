import AppKit
import AVFoundation
import PugglePhotosKit

/// What the book view asks of its controller.
protocol BookViewDelegate: AnyObject {
    var layout: BookLayout { get }
    /// A page as a picture, at the view's resolution; nil for none. A cover's is its whole board, bigger than a page.
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
    /// A photo carried to a page and put down there, its own page or another: where its middle went, in that page's
    /// coordinates.
    func bookCommitMove(_ id: PhotoID, toPage page: Int, center: CGPoint)
    /// While a photo is resized by its corner: draw its page with it `factor` times as big as it was (`start`) when
    /// the drag began.
    func bookPreviewResize(_ id: PhotoID, from start: BookPlacement, factor: Double)
    /// When the resize ends. Let go where it began, nothing changes.
    func bookCommitResize(_ id: PhotoID, from start: BookPlacement, factor: Double)
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
/// Click the paper to turn a page, or drag it over; click a photo to pick it, then drag it, its round handle or its
/// corner to move, turn or resize it, or click it again to turn it over and read its back. A photo dragged is carried
/// above the pages, to put down on either one, or held at the book's edge, on another spread as the page turns. Sticky
/// notes move, stretch and turn the same way, and a double-click writes on one. Videos play while the pointer is over
/// them.
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
    private let stretchHandle = CAShapeLayer()
    private let desk = CAGradientLayer()
    private let book = CALayer()
    private let bookShadow = CALayer()
    private let leftPage = CALayer()
    private let rightPage = CALayer()
    /// The open cover's boards around the pages and the sheets stacked under each open page; for a ring binder, the
    /// spine between the pages and the rings over them.
    private let leftBoard = CALayer()
    private let rightBoard = CALayer()
    private let spinePanel = CALayer()
    private let leftStack = CALayer()
    private let rightStack = CALayer()
    private let rings = CALayer()
    /// While a page turns on the rings, the rings go through its holes: this copy of them runs on from the holes to
    /// the pages on the side it leans over, under it, while `rings` runs from the other side's pages to the holes.
    /// It goes in the turning leaf itself, in depth with the page.
    private let ringsUnder = CALayer()
    /// The turning leaf and the rings, seen in perspective among themselves and then laid flat over the pages. The
    /// book sorts what's in it by depth, and tipped in among the pages lying flat, the rings cut across them and
    /// muddled which of them went on top (the book's shadow came through where the spine should be).
    private let hinge = CALayer()
    /// How far the holes the rings go through are from the middle of the binding.
    private var ringReach: CGFloat = 0
    /// The turning page's angle about the binding: 0 lying on the right, -π lying on the left.
    private var leafAngle: CGFloat = 0
    /// What the binder was last drawn for, so it's drawn again only when that changes.
    private var binderDrawn: String?
    private var stacksDrawn: String?
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
        /// `start`: the photo as it was when its corner was taken hold of; `grab`: where on the corner, from the
        /// corner itself (in the photo's own coordinates), so that spot follows the pointer.
        case resize(id: PhotoID, page: Int, start: BookPlacement, grab: CGPoint)
        /// `clickTurns`: nothing was picked, so a click (not just a drag) turns the page.
        case page(forward: Bool, start: NSPoint, progress: CGFloat, clickTurns: Bool)
        case sticky(id: PhotoID, page: Int, start: NSPoint, sticky: BookSticky, moved: Bool)
        /// `grab`: where the corner was taken hold of, from the corner itself (in the note's own coordinates), so
        /// that spot stays under the pointer.
        case stretchSticky(id: PhotoID, page: Int, sticky: BookSticky, grab: CGPoint)
        case turnSticky(id: PhotoID, page: Int, sticky: BookSticky, startPointerAngle: Double)
        case writing(page: Int, start: NSPoint, writing: BookWriting, moved: Bool)
        /// `grab`: how far past the end of its lines the bar was taken hold of, so that spot stays under the pointer.
        case widenWriting(page: Int, writing: BookWriting, grab: CGFloat)
        case turnWriting(page: Int, writing: BookWriting, startPointerAngle: Double)
    }

    /// A handle on what's picked: a knob turns it, a sticky note's corner stretches it, the bar at writing's side
    /// widens its lines.
    private enum Handle {
        case turn, stretch, widen
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        desk.colors = BookScene.deskColors(dark: false)
        desk.type = .radial
        desk.startPoint = BookScene.deskCenter
        desk.endPoint = BookScene.deskEdge
        layer?.addSublayer(desk)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 2400
        book.sublayerTransform = perspective
        layer?.addSublayer(book)
        bookShadow.backgroundColor = NSColor.black.cgColor
        bookShadow.shadowColor = NSColor.black.cgColor
        bookShadow.shadowOpacity = BookStage.shadowOpacity
        bookShadow.shadowRadius = BookStage.shadowRadius
        bookShadow.shadowOffset = CGSize(width: 0, height: BookStage.shadowDrop)
        bookShadow.cornerRadius = BookStage.pageCornerRadius
        book.addSublayer(bookShadow)
        // A binder's boards, spine and stacked sheets lie under the pages; its rings, over them.
        for part in [leftBoard, rightBoard, spinePanel, leftStack, rightStack] {
            part.isHidden = true
            part.contentsGravity = .resize
            book.addSublayer(part)
        }
        for page in [leftPage, rightPage] {
            page.contentsGravity = .resize
            page.masksToBounds = true
            book.addSublayer(page)
        }
        // A turning page goes under the rings, and over the copy of them that goes in it.
        hinge.sublayerTransform = perspective
        book.addSublayer(hinge)
        rings.isHidden = true
        rings.contentsGravity = .resize
        hinge.addSublayer(rings)
        ringsUnder.contentsGravity = .resize
        leftPage.cornerRadius = 4
        leftPage.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        rightPage.cornerRadius = 4
        rightPage.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        selection.fillColor = nil
        selection.lineWidth = 2.5
        selection.isHidden = true
        handle.isHidden = true
        handle.lineWidth = 2
        for layer in [handle, stretchHandle] {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 2
            layer.shadowOffset = CGSize(width: 0, height: 1)
        }
        book.addSublayer(selection)
        book.addSublayer(handle)
        stretchHandle.isHidden = true
        stretchHandle.lineWidth = 2
        book.addSublayer(stretchHandle)
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

    /// Whether the book lies on the desk by night.
    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        desk.colors = BookScene.deskColors(dark: isDark)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selection.strokeColor = Theme.accent.cgColor
            handle.strokeColor = Theme.accent.cgColor
            handle.fillColor = NSColor.white.cgColor
            stretchHandle.strokeColor = Theme.accent.cgColor
            stretchHandle.fillColor = NSColor.white.cgColor
        }
    }

    // MARK: Geometry

    /// How the book is bound.
    private var binding: BookBinding { delegate?.layout.settings.binding ?? .glued }

    /// Where everything lies on the desk: worked out the same way for a PDF page, so the book looks the same there.
    var stage: BookStage { BookStage(size: bounds.size, binding: binding) }

    /// The size of one page on screen: two pages side by side, and a binder's spine between them, fit the room, with
    /// space left around the cover's boards.
    var pageSize: CGSize { stage.pageSize }

    /// How wide a binder's spine shows between the open pages; glued pages meet.
    var spineGap: CGFloat { stage.spineGap }

    /// Where the spine is: the middle of the binding, which the pages turn about.
    private var spine: CGPoint { stage.spine }

    func pageRect(left: Bool) -> CGRect { stage.pageRect(left: left) }

    /// How far the book slides so a closed cover sits in the middle.
    private func offset(for state: Int) -> CGFloat {
        guard let layout = delegate?.layout else { return 0 }
        return stage.offset(state: state, stateCount: layout.stateCount)
    }

    /// A point on a page (page coordinates) in the view.
    func viewPoint(_ point: CGPoint, onLeft: Bool) -> CGPoint {
        let rect = pageRect(left: onLeft)
        let scale = rect.width / BookLayout.pageSize.width
        return CGPoint(x: rect.minX + point.x * scale + offset(for: state), y: rect.minY + point.y * scale)
    }

    /// Which way the book opens from a point on a closed cover's board (forward at the front, back at the back), if
    /// the point is on one.
    private func closedCoverOpens(at point: NSPoint) -> Bool? {
        guard let layout = delegate?.layout else { return nil }
        let pages = layout.state(state), shift = offset(for: state)
        if pages.left == nil, stage.rightBoard.offsetBy(dx: shift, dy: 0).contains(point) { return true }
        if pages.right == nil, stage.leftBoard.offsetBy(dx: shift, dy: 0).contains(point) { return false }
        return nil
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
        // Its size and middle, never its frame: the book is slid sideways by its transform to center a closed cover,
        // and setting the frame of a slid layer folds the slide into its position, so once the slide changed (the book
        // opening) everything was drawn off to one side of where it's clicked.
        book.bounds = CGRect(origin: .zero, size: bounds.size)
        book.position = CGPoint(x: bounds.midX, y: bounds.midY)
        hinge.bounds = book.bounds
        hinge.position = CGPoint(x: book.bounds.midX, y: book.bounds.midY)
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
        placePages(closedFront: pages.left == nil, closedBack: pages.right == nil)
        leftPage.contents = pages.left.flatMap(delegate.pageImage)
        rightPage.contents = pages.right.flatMap(delegate.pageImage)
        leftPage.isHidden = pages.left == nil
        rightPage.isHidden = pages.right == nil
        layoutBinder(pages)
        // Its corners as round as those of what casts it, so none shows past them.
        let shadow = stage.shadow(open: pages.left != nil && pages.right != nil, closedOnLeft: pages.left != nil)
        bookShadow.frame = shadow.rect
        bookShadow.cornerRadius = shadow.radius
        CATransaction.commit()
        updateSelection()
        refreshVideos()
        spots = nil
        if announcedState != state {
            announcedState = state
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// Lays the page pictures where they show: open pages side by side, and a closed cover over its whole board, which
    /// reaches past the pages under it as an open board does.
    private func placePages(closedFront: Bool, closedBack: Bool) {
        let stage = stage
        leftPage.frame = closedBack ? stage.leftBoard : stage.pageRect(left: true)
        rightPage.frame = closedFront ? stage.rightBoard : stage.pageRect(left: false)
        leftPage.cornerRadius = closedBack ? stage.boardRadius : BookStage.pageCornerRadius
        rightPage.cornerRadius = closedFront ? stage.boardRadius : BookStage.pageCornerRadius
    }

    /// The sizes the stacked sheets were last drawn at, left and right.
    private var stackSizes = (left: CGSize.zero, right: CGSize.zero)

    /// The open cover's boards around the pages, a little bigger than them, and the sheets stacked under each open
    /// page; for a ring binder, the spine between the pages and the rings over them. Shown while the book lies open,
    /// and drawn again only when its look or size changes (the stacks, when the place in it does).
    private func layoutBinder(_ pages: (left: Int?, right: Int?)) {
        let open = pages.left != nil && pages.right != nil
        for part in [leftBoard, rightBoard, leftStack, rightStack] { part.isHidden = !open }
        for part in [spinePanel, rings] {
            part.isHidden = !(open && binding.hasRings)
            part.mask = nil
        }
        // The rings lie flat again, all over the pages, once no page is turning on them.
        if leaf == nil {
            for part in [rings, ringsUnder] {
                part.removeAnimation(forKey: "turn")
                part.transform = CATransform3DIdentity
            }
            ringsUnder.removeFromSuperlayer()
        }
        guard let layout = delegate?.layout else { return }
        let settings = layout.settings
        let stage = stage
        let left = stage.pageRect(left: true)
        let thickness = stage.ringThickness
        let scale = window?.backingScaleFactor ?? 2
        leftBoard.frame = stage.leftBoard
        rightBoard.frame = stage.rightBoard
        spinePanel.frame = stage.spinePanel
        // Their middle is the middle of the binding, which the pages turn about. (Placed by bounds and position, as
        // they're tipped in depth while a page turns.)
        let ringBox = stage.ringBox
        rings.bounds = CGRect(origin: .zero, size: ringBox.size)
        rings.position = CGPoint(x: ringBox.midX, y: ringBox.midY)
        ringsUnder.bounds = rings.bounds
        ringReach = stage.ringReach
        let look = "\(settings.binding)-\(settings.rings)-\(settings.cover)-\(left.size)-\(scale)"
        if binderDrawn != look {
            binderDrawn = look
            let folds = !settings.binding.hasRings
            leftBoard.contents = BinderArt.board(size: leftBoard.bounds.size, cover: settings.cover, spineOnRight: true, folds: folds, scale: scale)
            rightBoard.contents = BinderArt.board(size: rightBoard.bounds.size, cover: settings.cover, spineOnRight: false, folds: folds, scale: scale)
            if settings.binding.hasRings {
                spinePanel.contents = BinderArt.spine(size: spinePanel.bounds.size, cover: settings.cover, finish: settings.rings,
                                                      rings: stage.spineRingHeights, scale: scale)
                rings.contents = BinderArt.rings(size: rings.bounds.size, finish: settings.rings, rings: stage.ringHeights,
                                                 from: thickness * 2, to: rings.bounds.width - thickness * 2, thickness: thickness, scale: scale)
            } else {
                spinePanel.contents = nil
                rings.contents = nil
            }
        }
        if open { layoutStacks(pages) }
    }

    /// The sheets lying under open pages: those already turned under the left page, those still to come under the
    /// right, drawn again only when their number or look changes.
    private func layoutStacks(_ pages: (left: Int?, right: Int?)) {
        guard let layout = delegate?.layout else { return }
        let settings = layout.settings
        let stage = stage
        let left = stage.pageRect(left: true), right = stage.pageRect(left: false)
        let scale = window?.backingScaleFactor ?? 2
        let (before, after) = BookScene.sheets(under: pages, in: layout)
        let stacks = "\(binderDrawn ?? "")-\(settings.paper)-\(before)-\(after)"
        if stacksDrawn != stacks {
            stacksDrawn = stacks
            let leftArt = BinderArt.stack(sheets: before, height: left.height, paper: settings.paper, onLeft: true, scale: scale)
            let rightArt = BinderArt.stack(sheets: after, height: right.height, paper: settings.paper, onLeft: false, scale: scale)
            leftStack.contents = leftArt?.image
            rightStack.contents = rightArt?.image
            stackSizes = (leftArt?.size ?? .zero, rightArt?.size ?? .zero)
        }
        leftStack.frame = CGRect(x: left.minX - stackSizes.left.width, y: left.minY, width: stackSizes.left.width, height: stackSizes.left.height)
        rightStack.frame = CGRect(x: right.maxX, y: right.minY, width: stackSizes.right.width, height: stackSizes.right.height)
    }

    /// The rings while a page turns on them, at `angle` about the binding (0 lying on the right, -π on the left).
    ///
    /// Each ring goes round the middle of the binding, through the holes of the pages lying on either side and of
    /// the page turning, which has carried its holes up round the rings with it: at a lift of θ, to (R cos θ, R sin θ)
    /// across and up from the middle, R being how far the holes are from it. So one copy of the rings runs from the
    /// left page's holes up to the turning page's, the straight way, 2R cos(θ/2) long and tipped up θ/2, and
    /// another runs on down to the right page's, 2R sin(θ/2) long and tipped π/2 - θ/2; squeezed to those lengths
    /// about the holes they stay in, and tipped up about them, the book's perspective draws each where its ends
    /// meet the holes. The copy on the side the page leans away from lies over it; the other, under it.
    private func ringPlacement(at angle: CGFloat, leaningRight: Bool) -> (over: CATransform3D, under: CATransform3D) {
        let lift = min(.pi, max(0, -angle))
        func laid(from hole: CGFloat, squeeze: CGFloat, tip: CGFloat) -> CATransform3D {
            var laid = CATransform3DMakeTranslation(-hole, 0, 0)
            laid = CATransform3DConcat(laid, CATransform3DMakeScale(max(0.002, squeeze), 1, 1))
            laid = CATransform3DConcat(laid, CATransform3DMakeRotation(tip, 0, 1, 0))
            return CATransform3DConcat(laid, CATransform3DMakeTranslation(hole, 0, 0))
        }
        let fromLeft = laid(from: -ringReach, squeeze: cos(lift / 2), tip: -lift / 2)
        let toRight = laid(from: ringReach, squeeze: sin(lift / 2), tip: .pi / 2 - lift / 2)
        return leaningRight ? (fromLeft, toRight) : (toRight, fromLeft)
    }

    /// Whether a page is turning on the rings, with the rings going through it.
    private var ringsTurning: Bool { leaf != nil && ringsUnder.superlayer === leaf }

    /// The rings under the turning page, laid as `under` but inside the leaf, so turned back by the leaf's own angle.
    private func inLeaf(_ under: CATransform3D, at angle: CGFloat) -> CATransform3D {
        CATransform3DConcat(under, CATransform3DMakeRotation(-angle, 0, 1, 0))
    }

    /// Lays the rings through the turning page's holes, the page at `angle`.
    private func placeRings(at angle: CGFloat) {
        guard ringsTurning else { return }
        let placement = ringPlacement(at: angle, leaningRight: angle >= -.pi / 2)
        rings.transform = placement.over
        ringsUnder.transform = inLeaf(placement.under, at: angle)
    }

    /// Keeps the rings through the turning page's holes while it turns from `start` to `end`, with the same timing,
    /// laid as they should be at points along the way.
    private func animateRings(from start: CGFloat, to end: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction?) {
        guard ringsTurning, start != end else { return }
        var times: [NSNumber] = [], over: [NSValue] = [], under: [NSValue] = []
        func add(_ share: CGFloat, leaningRight: Bool) {
            let angle = start + (end - start) * share
            let placement = ringPlacement(at: angle, leaningRight: leaningRight)
            times.append(NSNumber(value: Double(share)))
            over.append(NSValue(caTransform3D: placement.over))
            under.append(NSValue(caTransform3D: inLeaf(placement.under, at: angle)))
        }
        let steps = 36
        var leaned: Bool?
        for step in 0...steps {
            let share = CGFloat(step) / CGFloat(steps)
            let angle = start + (end - start) * share
            let right = angle == -.pi / 2 ? end > -.pi / 2 : angle > -.pi / 2
            // Where it stands upright, the rings over and under it trade places all at once.
            if let leaned, leaned != right {
                let upright = (-.pi / 2 - start) / (end - start)
                add(upright, leaningRight: leaned)
                add(upright, leaningRight: right)
            }
            add(share, leaningRight: right)
            leaned = right
        }
        for (part, values) in [(rings, over), (ringsUnder, under)] {
            let follow = CAKeyframeAnimation(keyPath: "transform")
            follow.values = values
            follow.keyTimes = times
            follow.duration = duration
            follow.timingFunction = timing
            if let last = values.last { part.transform = last.caTransform3DValue }
            part.add(follow, forKey: "turn")
        }
    }

    #if DEBUG
    /// How many rings show over the open pages, for the self-test.
    var ringCountForTesting: Int { rings.isHidden || rings.contents == nil ? 0 : binding.ringPositions.count }

    /// A point `z` up from a layer that draws what's in it flat, as it's drawn there: through the layer's
    /// perspective, about its middle.
    private func flattenedForTesting(_ p: (x: CGFloat, y: CGFloat, z: CGFloat), in layer: CALayer) -> CGPoint {
        let s = layer.sublayerTransform
        let x = p.x - layer.bounds.midX, y = p.y - layer.bounds.midY
        let w = x * s.m14 + y * s.m24 + p.z * s.m34 + s.m44
        return CGPoint(x: layer.bounds.midX + (x * s.m11 + y * s.m21 + p.z * s.m31 + s.m41) / w,
                       y: layer.bounds.midY + (x * s.m12 + y * s.m22 + p.z * s.m32 + s.m42) / w)
    }

    /// Where a point in the book, `z` up from its pages, shows in the view: through its perspective, and its slide.
    /// With `presented`, as it shows right now, partway through a turn.
    private func seenForTesting(_ p: (x: CGFloat, y: CGFloat, z: CGFloat), presented: Bool) -> CGPoint {
        let book = presented ? book.presentation() ?? book : book
        let flat = flattenedForTesting(p, in: book)
        return CGPoint(x: flat.x - book.bounds.midX + book.position.x + book.transform.m41,
                       y: flat.y - book.bounds.midY + book.position.y + book.transform.m42)
    }

    /// Where a point on a layer in the book shows in the view: through its transform about its anchor, and those of
    /// the layers it's in, up to the book, each but a transform layer drawing what's in it flat.
    private func shownForTesting(_ point: CGPoint, on part: CALayer, presented: Bool) -> CGPoint {
        var p = (x: point.x, y: point.y, z: CGFloat(0))
        var layer = part
        while layer !== book, let parent = layer.superlayer {
            let shown = presented ? layer.presentation() ?? layer : layer
            let x = p.x - shown.bounds.minX - shown.anchorPoint.x * shown.bounds.width
            let y = p.y - shown.bounds.minY - shown.anchorPoint.y * shown.bounds.height
            let t = shown.transform
            let w = x * t.m14 + y * t.m24 + p.z * t.m34 + t.m44
            p = (x: shown.position.x + (x * t.m11 + y * t.m21 + p.z * t.m31 + t.m41) / w,
                 y: shown.position.y + (x * t.m12 + y * t.m22 + p.z * t.m32 + t.m42) / w,
                 z: shown.zPosition + (x * t.m13 + y * t.m23 + p.z * t.m33 + t.m43) / w)
            layer = parent
            if parent !== book, !(parent is CATransformLayer) {
                let flat = flattenedForTesting(p, in: presented ? parent.presentation() ?? parent : parent)
                p = (x: flat.x, y: flat.y, z: 0)
            }
        }
        return seenForTesting(p, presented: presented)
    }

    /// While a page turns on rings: how far, at most, the ends of the rings over and under it miss the holes they
    /// go through (the turning page's, and those of the pages lying either side), and whether the rings over it come
    /// from the left page's holes. With `presented`, as they show right now, partway through an animated turn.
    func ringsThroughHolesForTesting(presented: Bool = false) -> (miss: CGFloat, overFromLeft: Bool)? {
        guard let leaf, ringsTurning, !binding.ringPositions.isEmpty else { return nil }
        let height = leaf.bounds.height, inset = (rings.bounds.height - height) / 2
        func apart(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        var miss: CGFloat = 0, overFromLeft = true
        for share in binding.ringPositions {
            let y = inset + share * height
            let turning = shownForTesting(CGPoint(x: ringReach, y: share * height), on: leaf, presented: presented)
            let lying = [-ringReach, ringReach].map {
                seenForTesting((x: rings.position.x + $0, y: rings.position.y - rings.bounds.height / 2 + y, z: 0), presented: presented)
            }
            let over = [-ringReach, ringReach].map { shownForTesting(CGPoint(x: rings.bounds.midX + $0, y: y), on: rings, presented: presented) }
            let under = [-ringReach, ringReach].map { shownForTesting(CGPoint(x: rings.bounds.midX + $0, y: y), on: ringsUnder, presented: presented) }
            overFromLeft = apart(over[1], turning) < apart(over[0], turning)
            let pairs = overFromLeft ? [(over[0], lying[0]), (over[1], turning), (under[0], turning), (under[1], lying[1])]
                : [(over[0], turning), (over[1], lying[1]), (under[0], lying[0]), (under[1], turning)]
            miss = max(miss, pairs.map { apart($0.0, $0.1) }.max() ?? 0)
        }
        return (miss, overFromLeft)
    }

    /// How far over the turning page shows right now, 0 lying where it started to 1 turned all the way, from its
    /// angle as drawn partway through an animated turn; nil when no page is turning.
    var shownTurnForTesting: CGFloat? {
        guard let leaf, let shown = leaf.presentation() else { return nil }
        let over = acos(max(-1, min(1, shown.transform.m11))) / .pi
        return turningForward ? over : 1 - over
    }

    /// The closed cover as it lies in the view, slid to the middle; nil while the book lies open.
    var closedCoverForTesting: CGRect? {
        guard let layout = delegate?.layout, !isTurning else { return nil }
        let pages = layout.state(state)
        let shown = pages.left == nil ? rightPage : (pages.right == nil ? leftPage : nil)
        return shown.map { $0.frame.offsetBy(dx: offset(for: state), dy: 0) }
    }

    /// While a leaf turns: how big each of its faces is, and where an endpaper lies on a cover's inside.
    var turningFaceForTesting: (face: CGSize, endpaper: CGRect?)? {
        guard let leaf, let face = leaf.sublayers?.first else { return nil }
        let endpaper = leaf.sublayers?.lazy.compactMap { $0.sublayers?.first { $0.name == "endpaper" }?.frame }.first
        return (face.bounds.size, endpaper)
    }

    /// How much of a binder's spine and rings shows across the view, from where to where (nil for none), and where the
    /// edge of a turning cover shows.
    var binderShownForTesting: (spine: ClosedRange<CGFloat>?, rings: ClosedRange<CGFloat>?, coverEdge: CGFloat?) {
        let slide = book.transform.m41
        func shown(_ part: CALayer) -> ClosedRange<CGFloat>? {
            guard !part.isHidden, part.contents != nil else { return nil }
            var low = part.frame.minX, high = part.frame.maxX
            if let mask = part.mask {
                let edge = part.frame.minX + mask.position.x
                if mask.anchorPoint.x == 0 { low = max(low, edge) } else { high = min(high, edge) }
            }
            return low < high ? (low + slide)...(high + slide) : nil
        }
        return (shown(spinePanel), shown(rings), leaf.map { coverEdge(at: leafAngle, reach: $0.bounds.width) + slide })
    }

    /// Whether the open cover shows around the pages, a margin of it past their outer edges.
    var coverShowsForTesting: Bool {
        !leftBoard.isHidden && !rightBoard.isHidden && leftBoard.contents != nil
            && leftBoard.frame.minX < pageRect(left: true).minX - 4 && rightBoard.frame.maxX > pageRect(left: false).maxX + 4
    }
    #endif

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
        // Turned through the angle between, so it always lifts toward the eye and over.
        let rotation = CABasicAnimation(keyPath: "transform")
        rotation.valueFunction = CAValueFunction(name: .rotateY)
        rotation.fromValue = Double(start)
        rotation.toValue = Double(end)
        let remaining = duration * Double(1 - progress)
        rotation.duration = max(0.15, remaining)
        rotation.timingFunction = CAMediaTimingFunction(name: progress > 0 ? .easeOut : .easeInEaseOut)
        leaf.transform = CATransform3DMakeRotation(end, 0, 1, 0)
        leaf.add(rotation, forKey: "turn")
        leafAngle = end
        animateRings(from: start, to: end, duration: rotation.duration, timing: rotation.timingFunction)
        animateBinderInside(from: start, to: end, duration: rotation.duration, timing: rotation.timingFunction)
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
        // The book opening or closing: the leaf turning is a cover, the front one or the back.
        let from = layout.state(state)
        let isCover = [from.left, from.right, under.left, under.right].contains { $0 == nil }
        let atFront = target == 0 || state == 0
        coverTurning = isCover ? atFront : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let stage = stage
        let rect = stage.pageRect(left: false)
        // The leaf turns about the middle of the binding: the spine where glued pages meet, or a binder's rings, with
        // the page held half the spine's width off them. A cover is its whole board, reaching past the pages at the
        // top, the bottom and its outer edge, so its border shows all the way over, as it does lying open or closed.
        let half = spineGap / 2
        let margin = isCover ? stage.boardMargin : 0
        let leaf = CATransformLayer()
        leaf.anchorPoint = CGPoint(x: 0, y: 0.5)
        leaf.bounds = CGRect(x: 0, y: 0, width: rect.width + margin + half, height: rect.height + margin * 2)
        leaf.position = CGPoint(x: spine.x, y: rect.midY)
        let face = CGRect(x: half, y: 0, width: rect.width + margin, height: rect.height + margin * 2)
        let front = CALayer()
        front.frame = face
        front.contentsGravity = .resize
        front.isDoubleSided = false
        let back = CALayer()
        back.frame = face
        back.contentsGravity = .resize
        back.isDoubleSided = false
        back.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        if isCover {
            // Outside, the cover's own picture of its board; inside, the board with the endpaper pasted on it, as it lies
            // open: on the left for the front cover (the leaf's back), on the right for the back cover (its front).
            let page = CGSize(width: rect.width, height: rect.height)
            if atFront {
                front.contents = delegate.pageImage(pages.front)
                back.contents = leftBoard.contents
                back.addSublayer(pasted(delegate.pageImage(pages.back), in: CGRect(origin: CGPoint(x: margin, y: margin), size: page), outerOnLeft: true))
            } else {
                front.contents = rightBoard.contents
                front.addSublayer(pasted(delegate.pageImage(pages.front), in: CGRect(origin: CGPoint(x: 0, y: margin), size: page), outerOnLeft: false))
                back.contents = delegate.pageImage(pages.back)
            }
        } else {
            front.contents = delegate.pageImage(pages.front)
            back.contents = delegate.pageImage(pages.back)
        }
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
        leafAngle = forward ? 0 : -.pi
        leaf.transform = CATransform3DMakeRotation(leafAngle, 0, 1, 0)
        // Between a binder's rings under it and over it, as it turns on them.
        hinge.insertSublayer(leaf, below: rings)
        self.leaf = leaf
        // Under the leaf: going forward, the next spread's right page; going back, the earlier one's left page. Pages
        // lie open around a turning leaf, even one closing over them.
        placePages(closedFront: false, closedBack: false)
        if forward {
            rightPage.contents = under.right.flatMap(delegate.pageImage)
            rightPage.isHidden = under.right == nil
        } else {
            leftPage.contents = under.left.flatMap(delegate.pageImage)
            leftPage.isHidden = under.left == nil
        }
        // The book opening or closing: the turning leaf is a cover itself, so the board staying under the pages shows
        // (the back one under the right page at the front of the book, the front one at the back), with the sheets
        // lying on it. A binder's spine and rings stay at the binding, inside the book: they show only where the cover
        // has swung clear of them, never out past its edge.
        if isCover {
            for part in [leftBoard, spinePanel, leftStack, rightStack, rings, rightBoard] { part.isHidden = true }
            (atFront ? rightBoard : leftBoard).isHidden = false
            layoutStacks([from, under].first { $0.left != nil && $0.right != nil } ?? under)
            (atFront ? rightStack : leftStack).isHidden = false
            if binding.hasRings {
                for part in [spinePanel, rings] {
                    part.isHidden = false
                    let mask = CALayer()
                    mask.backgroundColor = NSColor.black.cgColor
                    mask.bounds = CGRect(x: 0, y: 0, width: 100_000, height: 100_000)
                    // The front cover's inside is past its edge toward the back board; the back cover's, toward the front.
                    mask.anchorPoint = CGPoint(x: atFront ? 0 : 1, y: 0.5)
                    mask.position = CGPoint(x: coverEdge(at: leafAngle, reach: leaf.bounds.width) - part.frame.minX, y: part.bounds.midY)
                    part.mask = mask
                }
            }
            bookShadow.frame = (atFront ? rightBoard : leftBoard).frame
            bookShadow.cornerRadius = stage.boardRadius
        } else if !rings.isHidden {
            // Turning on a binder's rings, which go on through its holes: the copy under it in the leaf, its middle
            // on the leaf's hinge, which is the rings' middle too.
            ringsUnder.contents = rings.contents
            ringsUnder.position = CGPoint(x: 0, y: leaf.bounds.height / 2)
            leaf.insertSublayer(ringsUnder, at: 0)
            placeRings(at: leafAngle)
        }
        CATransaction.commit()
    }

    /// Takes the turned leaf away, there and then: left to Core Animation, it faded out over the pages laid where it
    /// landed, a picture of it lingering for as long as seconds while the app was busy.
    private func removeLeaf() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leaf?.removeFromSuperlayer()
        CATransaction.commit()
        leaf = nil
    }

    /// An endpaper pasted on a cover's board, in the leaf: the page's picture, its outer corners rounded as a page's are.
    private func pasted(_ image: CGImage?, in rect: CGRect, outerOnLeft: Bool) -> CALayer {
        let paper = CALayer()
        paper.name = "endpaper"
        paper.frame = rect
        paper.contents = image
        paper.contentsGravity = .resize
        paper.isDoubleSided = false
        paper.cornerRadius = BookStage.pageCornerRadius
        paper.maskedCorners = outerOnLeft ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        paper.masksToBounds = true
        return paper
    }

    /// While a cover turns, whether it's the front one (nil while no cover is turning).
    private var coverTurning: Bool?

    /// Where a turning cover's outer edge shows across the book, `reach` out from the middle of the binding, at
    /// `angle`: through the perspective it turns in. A binder's spine and rings show only on the cover's inside of that
    /// line. Out past it they'd lie on the desk, outside the book; under the cover, it hides them anyway.
    private func coverEdge(at angle: CGFloat, reach: CGFloat) -> CGFloat {
        let lift = -reach * sin(angle)
        return spine.x + reach * cos(angle) / (1 + lift * hinge.sublayerTransform.m34)
    }

    /// Keeps a binder's spine and rings inside the book while the cover turns from `start` to `end`, with the same timing:
    /// shown up to its outer edge as it goes.
    private func animateBinderInside(from start: CGFloat, to end: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction?) {
        guard coverTurning != nil, let leaf, start != end else { return }
        let steps = 36
        let shares = (0...steps).map { CGFloat($0) / CGFloat(steps) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [spinePanel, rings] {
            guard let mask = part.mask else { continue }
            let values = shares.map { coverEdge(at: start + (end - start) * $0, reach: leaf.bounds.width) - part.frame.minX }
            let follow = CAKeyframeAnimation(keyPath: "position.x")
            follow.values = values.map { NSNumber(value: Double($0)) }
            follow.keyTimes = shares.map { NSNumber(value: Double($0)) }
            follow.duration = duration
            follow.timingFunction = timing
            mask.position.x = values.last ?? mask.position.x
            mask.add(follow, forKey: "follow")
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
        carryOn()
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
        removeLeaf()
        coverTurning = nil
        isTurning = false
        state = target
        reload()
        delegate?.bookDidChangeState(state)
        carryOn()
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
        leafAngle = forward ? -CGFloat.pi * progress : -CGFloat.pi * (1 - progress)
        leaf?.transform = CATransform3DMakeRotation(leafAngle, 0, 1, 0)
        placeRings(at: leafAngle)
        if coverTurning != nil, let leaf {
            for part in [spinePanel, rings] { part.mask?.position.x = coverEdge(at: leafAngle, reach: leaf.bounds.width) - part.frame.minX }
        }
        CATransaction.commit()
    }

    #if DEBUG
    /// Holds a page partway through turning, for screenshots.
    func holdTurn(at progress: CGFloat) { dragTurn(forward: true, progress: progress) }
    /// Lets go of a page held partway through turning, as a drag let go there.
    func letGoOfTurn(at progress: CGFloat) { endDragTurn(forward: true, progress: progress) }
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
                    self.removeLeaf()
                    self.coverTurning = nil
                    self.isTurning = false
                    self.reload()
                }
            }
            let flat: CGFloat = forward ? 0 : -.pi
            let rotation = CABasicAnimation(keyPath: "transform")
            rotation.valueFunction = CAValueFunction(name: .rotateY)
            rotation.fromValue = Double(leafAngle)
            rotation.toValue = Double(flat)
            rotation.duration = 0.25
            leaf.transform = CATransform3DMakeRotation(flat, 0, 1, 0)
            leaf.add(rotation, forKey: "settle")
            animateRings(from: leafAngle, to: flat, duration: rotation.duration, timing: nil)
            animateBinderInside(from: leafAngle, to: flat, duration: rotation.duration, timing: nil)
            leafAngle = flat
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

    /// Where a knob can be taken hold of: a square around it, generously, and two smaller ones along the outer part
    /// of its stalk (never reaching what it turns, at any lean).
    private static func knobSpots(_ knob: (top: CGPoint, turn: CGPoint)) -> [NSRect] {
        [spot(around: knob.turn, width: 34, height: 34)] + [0.4, 0.65].map { (along: CGFloat) in
            spot(around: CGPoint(x: knob.top.x + (knob.turn.x - knob.top.x) * along, y: knob.top.y + (knob.turn.y - knob.top.y) * along),
                 width: 14, height: 14)
        }
    }

    private static func spot(around point: CGPoint, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }

    /// Where the handles of what's picked can be taken hold of, in the view: around each knob, and around the corner
    /// or bar that stretches it (first, so it wins where they meet). None while a photo or a page turns, while a
    /// photo is being carried, or while writing is being written.
    private func handleSpots() -> [(handle: Handle, rect: NSRect)] {
        guard !isTurning, turnLayer == nil, lift == nil else { return [] }
        if editing == nil, let (writing, _, left) = writingPlace(), let size = delegate?.bookWritingSize(writing) {
            let handles = writingHandles(writing, size: size, left: left)
            return [(.widen, Self.spot(around: handles.widen, width: 22, height: 36))] + Self.knobSpots((handles.top, handles.turn)).map { (.turn, $0) }
        }
        if let (placement, _, left) = stickyPlacement() {
            let handles = stickyHandles(placement, left: left)
            return [(.stretch, Self.spot(around: handles.stretch, width: 26, height: 26))]
                + Self.knobSpots((handles.top, handles.turn)).map { (.turn, $0) }
        }
        guard let knob = photoKnob() else { return [] }
        return (photoCorner().map { [(Handle.stretch, Self.spot(around: $0, width: 26, height: 26))] } ?? [])
            + Self.knobSpots(knob).map { (.turn, $0) }
    }

    /// The picked photo's bottom right corner, in the view, which resizes it.
    private func photoCorner() -> CGPoint? {
        guard let (placement, _, left) = selectedPlacement(), let frame = delegate?.layout.settings.frame else { return nil }
        let rect = placement.frameRect(frame)
        return viewPoint(placement.page(CGPoint(x: rect.maxX, y: rect.maxY)), onLeft: left)
    }

    private func handle(at point: NSPoint) -> Handle? {
        handleSpots().first { $0.rect.contains(point) }?.handle
    }

    /// Takes hold of a handle of what's picked, remembering where: knobs turn from the pointer's angle then, and
    /// the spot taken hold of on a corner or bar stays under the pointer.
    private func takeHold(of handle: Handle, at point: NSPoint) {
        if let (writing, page, _) = writingPlace() {
            let pointer = pageCoordinates(point, onPage: page)
            if handle == .widen {
                drag = .widenWriting(page: page, writing: writing, grab: writing.local(pointer).x - writing.width / 2)
            } else {
                drag = .turnWriting(page: page, writing: writing, startPointerAngle: atan2(pointer.y - writing.center.y, pointer.x - writing.center.x))
            }
        } else if let (placement, page, _) = stickyPlacement() {
            let pointer = pageCoordinates(point, onPage: page)
            if handle == .stretch {
                let local = placement.stickyLocal(pointer)
                drag = .stretchSticky(id: placement.id, page: page, sticky: placement.sticky,
                                      grab: CGPoint(x: local.x - placement.sticky.size.width / 2, y: local.y - placement.sticky.size.height / 2))
            } else {
                let middle = placement.stickyPage(.zero)
                drag = .turnSticky(id: placement.id, page: page, sticky: placement.sticky,
                                   startPointerAngle: atan2(pointer.y - middle.y, pointer.x - middle.x))
            }
        } else if let (placement, page, _) = selectedPlacement() {
            // From the page's own coordinates even when the handle stands off the page, so the photo doesn't jump.
            let pointer = pageCoordinates(point, onPage: page)
            if handle == .stretch, let frame = delegate?.layout.settings.frame {
                let rect = placement.frameRect(frame), local = placement.local(pointer)
                drag = .resize(id: placement.id, page: page, start: placement, grab: CGPoint(x: local.x - rect.maxX, y: local.y - rect.maxY))
            } else {
                drag = .rotate(id: placement.id, page: page, center: placement.center, startAngle: placement.angle,
                               startPointerAngle: atan2(pointer.y - placement.center.y, pointer.x - placement.center.x))
            }
        }
    }

    // MARK: The pointer

    /// Where the pointer changes: a hand over the handles, and while writing, the text cursor everywhere else. The
    /// pieces never overlap, so moving from one to the next can't leave the wrong pointer showing.
    private func cursorRects() -> [(rect: NSRect, cursor: NSCursor)] {
        let pieces = Self.split(visibleRect, by: handleSpots().map(\.rect))
        return pieces.inside.map { ($0, NSCursor.pointingHand) } + (isWriting ? pieces.outside.map { ($0, NSCursor.iBeam) } : [])
    }

    override func resetCursorRects() {
        for (rect, cursor) in cursorRects() { addCursorRect(rect, cursor: cursor) }
    }

    /// A rectangle cut into pieces that don't overlap: those some rectangles cover, and those they don't. It's cut
    /// across at every top and bottom edge, then each band along at the sides of what covers it.
    static func split(_ bounds: NSRect, by rects: [NSRect]) -> (inside: [NSRect], outside: [NSRect]) {
        let rects = rects.map { $0.intersection(bounds) }.filter { !$0.isEmpty }
        let edges = Set([bounds.minY, bounds.maxY] + rects.flatMap { [$0.minY, $0.maxY] }).sorted()
        var inside: [NSRect] = [], outside: [NSRect] = []
        for (top, bottom) in zip(edges, edges.dropFirst()) {
            var covered: [ClosedRange<CGFloat>] = []
            for rect in rects.filter({ $0.minY <= top && $0.maxY >= bottom }).sorted(by: { $0.minX < $1.minX }) {
                if let last = covered.last, rect.minX <= last.upperBound {
                    covered[covered.count - 1] = last.lowerBound...max(last.upperBound, rect.maxX)
                } else {
                    covered.append(rect.minX...rect.maxX)
                }
            }
            var x = bounds.minX
            for stretch in covered {
                if stretch.lowerBound > x { outside.append(NSRect(x: x, y: top, width: stretch.lowerBound - x, height: bottom - top)) }
                inside.append(NSRect(x: stretch.lowerBound, y: top, width: stretch.upperBound - stretch.lowerBound, height: bottom - top))
                x = stretch.upperBound
            }
            if bounds.maxX > x { outside.append(NSRect(x: x, y: top, width: bounds.maxX - x, height: bottom - top)) }
        }
        return (inside, outside)
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

    /// The pointer AppKit is given for each part of the view, for the self-test.
    var cursorRectsForTesting: [(rect: NSRect, cursor: NSCursor)] { cursorRects() }

    /// The pointer over a point: nil where the view leaves it as it is.
    func cursorForTesting(at point: NSPoint) -> NSCursor? { cursorRects().first { $0.rect.contains(point) }?.cursor }

    /// The middle of the bar at the picked writing's side, for the self-test.
    var widenBarForTesting: CGPoint? {
        guard let (writing, _, left) = writingPlace(), let size = delegate?.bookWritingSize(writing) else { return nil }
        return writingHandles(writing, size: size, left: left).widen
    }

    /// Where the knob and the corner (or bar) land in the view as drawn: their paths are made in each handle layer's
    /// own coordinates, and read back through the layers here, for the self-test to hold against where they take hold.
    var drawnHandlesForTesting: (knob: CGPoint?, stretch: CGPoint?) {
        guard let layer else { return (nil, nil) }
        let knob = handle.isHidden ? nil : knobForTesting.map { handle.convert($0.turn, to: layer) }
        let stretch = stretchHandle.isHidden ? nil : stretchHandle.path.map { path in
            let box = path.boundingBoxOfPath
            return stretchHandle.convert(CGPoint(x: box.midX, y: box.midY), to: layer)
        }
        return (knob, stretch)
    }

    /// The picked photo's corner as the pointer finds it, for the self-test.
    var photoCornerForTesting: CGPoint? { photoCorner() }

    /// `-PHShowHandleSpots YES`: where the handles take hold, painted over the book in the view's own coordinates.
    private var spotsOverlay: HandleSpotsOverlay?

    func showHandleSpotsForTesting() {
        let overlay = HandleSpotsOverlay(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        spotsOverlay = overlay
        overlay.rects = handleSpots().map(\.rect)
    }
    #endif

    private func updateSelection() {
        // Where the handles are has changed, and with it where the pointer becomes a hand.
        window?.invalidateCursorRects(for: self)
        #if DEBUG
        spotsOverlay?.rects = handleSpots().map(\.rect)
        #endif
        stretchHandle.isHidden = true
        // A photo being carried shows no outline or handles: it's in hand.
        if lift != nil {
            selection.isHidden = true
            handle.isHidden = true
            return
        }
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
            for layer in [selection, handle, stretchHandle] { layer.frame = book.bounds.offsetBy(dx: -offset, dy: 0) }
            selection.path = outline
            selection.lineDashPattern = [5, 4]
            handle.path = knob
            stretchHandle.path = widen
            selection.isHidden = false
            handle.isHidden = false
            stretchHandle.isHidden = false
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
            for layer in [selection, handle, stretchHandle] { layer.frame = book.bounds.offsetBy(dx: -offset, dy: 0) }
            selection.path = outline
            handle.path = knob
            stretchHandle.path = corner
            selection.isHidden = false
            handle.isHidden = false
            stretchHandle.isHidden = false
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
        // The bottom right corner resizes it.
        let corner = CGMutablePath()
        corner.addRoundedRect(in: CGRect(x: corners[2].x - 7, y: corners[2].y - 7, width: 14, height: 14), cornerWidth: 3, cornerHeight: 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let offset = offset(for: state)
        for layer in [selection, handle, stretchHandle] { layer.frame = book.bounds.offsetBy(dx: -offset, dy: 0) }
        selection.path = outline
        handle.path = knob
        stretchHandle.path = corner
        selection.isHidden = false
        handle.isHidden = false
        stretchHandle.isHidden = false
        CATransaction.commit()
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

    /// A sticky note stretched by its bottom right corner, its top left corner staying put: the spot on the corner
    /// taken hold of (`grab`, from the corner) goes to a point on the page.
    static func stretched(_ sticky: BookSticky, to point: CGPoint, on placement: BookPlacement, grab: CGPoint = .zero) -> BookSticky {
        var before = placement
        before.sticky = sticky
        let local = before.stickyLocal(point)
        let width = max(BookSticky.smallest.width, local.x - grab.x + sticky.size.width / 2)
        let height = max(BookSticky.smallest.height, local.y - grab.y + sticky.size.height / 2)
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
        stretchHandle.isHidden = true
        CATransaction.commit()
        turnLayer = container
        window?.invalidateCursorRects(for: self)
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

    // MARK: Carrying a photo to another page

    /// A photo lifted off its page while it's dragged: drawn above the book under the pointer, so it can be put down
    /// anywhere on either page, or, held at the book's outer edge while the page turns, on another spread.
    private struct Lift {
        let id: PhotoID
        let layer: CALayer
        /// From the pointer to the photo's middle, in the view, as when it was taken hold of.
        let grab: CGPoint
        /// Its page and middle before it was lifted.
        let page: Int
        let center: CGPoint
        let angle: Double
    }

    private var lift: Lift?
    /// Which way the page turns while a lifted photo is held at the book's edge; nil away from the edges.
    private var springForward: Bool?
    private var springWork: DispatchWorkItem?
    /// Where the pointer let go of a lifted photo while a page was still turning: it's put down once the turn ends.
    private var dropAfterTurn: NSPoint?

    /// How long a photo is held at the book's edge before the page turns, and how close to the edge that is.
    private static let springDelay: TimeInterval = 0.6
    private static let edgeReach: CGFloat = 24

    /// Whether a photo is being carried, for the self-test.
    var isCarryingPhoto: Bool { lift != nil }

    /// Picks a photo up off its page: the page is drawn without it, and a picture of it, a little bigger and casting
    /// a deeper shadow, follows the pointer. False when there's no picture of it to carry.
    private func liftPhoto(_ id: PhotoID, page: Int, pointer: NSPoint) -> Bool {
        guard let delegate, let layer, let placement = delegate.layout.find(id)?.placement else { return false }
        if turnedOver == id { setTurnedOver(nil) }
        let left = delegate.layout.state(state).left == page
        let scale = pageRect(left: left).width / BookLayout.pageSize.width
        guard let side = delegate.bookPhotoSide(id, back: false, scale: scale * (window?.backingScaleFactor ?? 2)) else { return false }
        let middle = viewPoint(placement.center, onLeft: left)
        let picture = CALayer()
        picture.contents = side.image
        picture.bounds = CGRect(x: 0, y: 0, width: side.size.width * scale, height: side.size.height * scale)
        picture.position = middle
        picture.setAffineTransform(CGAffineTransform(rotationAngle: placement.angle * .pi / 180).scaledBy(x: 1.03, y: 1.03))
        picture.shadowColor = NSColor.black.cgColor
        picture.shadowOpacity = 0.3
        picture.shadowRadius = 12
        picture.shadowOffset = CGSize(width: 0, height: 8)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.addSublayer(picture)
        CATransaction.commit()
        lift = Lift(id: id, layer: picture, grab: CGPoint(x: middle.x - pointer.x, y: middle.y - pointer.y), page: page,
                    center: placement.center, angle: placement.angle)
        stopVideo(id)
        delegate.bookSetTurnedOver(turnedOver, hiding: id)
        reloadPage(page)
        updateSelection()
        return true
    }

    private func moveLift(to pointer: NSPoint) {
        guard let lift else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift.layer.position = CGPoint(x: pointer.x + lift.grab.x, y: pointer.y + lift.grab.y)
        CATransaction.commit()
        springLoad(at: pointer)
    }

    /// Held at the book's outer edge, a lifted photo turns the page after a moment, and again as long as it's held
    /// there, while there's a page it can go on that way.
    private func springLoad(at pointer: NSPoint) {
        let forward = edge(at: pointer)
        guard forward != springForward else { return }
        springForward = forward
        springWork?.cancel()
        springWork = nil
        if let forward { scheduleSpring(forward) }
    }

    private func scheduleSpring(_ forward: Bool) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, lift != nil, springForward == forward, !isTurning, canCarry(forward: forward) else { return }
            turn(forward: forward)
        }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDelay, execute: work)
    }

    /// Which way the page turns for a photo held at the book's outer edge: back at the left page's, forward at the
    /// right page's; nil anywhere else.
    private func edge(at pointer: NSPoint) -> Bool? {
        guard let pages = delegate?.layout.state(state) else { return nil }
        let slide = offset(for: state)
        if pages.left != nil, pointer.x < pageRect(left: true).minX + slide + Self.edgeReach { return false }
        if pages.right != nil, pointer.x > pageRect(left: false).maxX + slide - Self.edgeReach { return true }
        return nil
    }

    /// Whether turning that way opens a page a photo can be put down on, next to the pointer: going back, the earlier
    /// spread's right page; going forward, the next spread's left page. At the first page of photos (or the last),
    /// there's none, and the page stays.
    private func canCarry(forward: Bool) -> Bool {
        guard let layout = delegate?.layout else { return false }
        let target = forward ? state + 1 : state - 1
        guard (0..<layout.stateCount).contains(target) else { return false }
        let pages = layout.state(target)
        return (forward ? pages.left : pages.right).map(layout.takesPhotos) ?? false
    }

    /// After a page turns with a photo in hand: put it down if the pointer let go meanwhile, or turn again after a
    /// moment if it's still held at the edge.
    private func carryOn() {
        guard lift != nil else { return }
        if let point = dropAfterTurn {
            dropAfterTurn = nil
            dropLift(at: point)
        } else if let forward = springForward {
            scheduleSpring(forward)
        }
    }

    /// Puts a lifted photo down where it is, on the page under it (or under the pointer) if photos can go there.
    /// Anywhere else, off the pages, it goes back where it came from.
    private func dropLift(at pointer: NSPoint) {
        guard let lift, let delegate else { return }
        if isTurning {
            dropAfterTurn = pointer
            return
        }
        springWork?.cancel()
        springWork = nil
        springForward = nil
        self.lift = nil
        let middle = CGPoint(x: pointer.x + lift.grab.x, y: pointer.y + lift.grab.y)
        let layout = delegate.layout
        if let target = [pagePoint(middle), pagePoint(pointer)].compactMap({ $0 }).first(where: { layout.takesPhotos($0.page) }) {
            let center = BookLayout.clamp(pageCoordinates(middle, onPage: target.page))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            delegate.bookSetTurnedOver(nil, hiding: nil)
            if target.page != lift.page || hypot(center.x - lift.center.x, center.y - lift.center.y) > 0.5 {
                delegate.bookCommitMove(lift.id, toPage: target.page, center: center)
            }
            reload()
            lift.layer.removeFromSuperlayer()
            CATransaction.commit()
            select(lift.id)
            return
        }
        // Back where it came from: onto its page if that's showing, otherwise it fades.
        let pages = layout.state(state)
        let homeLeft = pages.left == lift.page
        let homeShowing = homeLeft || pages.right == lift.page
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.isReduced ? 0 : 0.22)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.bookSetTurnedOver(nil, hiding: nil)
                self.reload()
                lift.layer.removeFromSuperlayer()
                if homeShowing { self.select(lift.id) }
            }
        }
        if homeShowing {
            lift.layer.position = viewPoint(lift.center, onLeft: homeLeft)
            lift.layer.setAffineTransform(CGAffineTransform(rotationAngle: lift.angle * .pi / 180))
        } else {
            lift.layer.opacity = 0
        }
        CATransaction.commit()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let delegate, !isTurning, let hit = pagePoint(point) else { return nil }
        if let writing = writing(at: hit.point, onPage: hit.page) {
            pick(.writing(writing.id))
            return delegate.bookWritingMenu(writing.id)
        }
        guard delegate.layout.pages[hit.page].holdsPhotos else { return delegate.bookPageMenu(hit.page) }
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

    /// Writing widened or narrowed by the bar at its side, its left side staying put: the spot on the bar taken
    /// hold of (`grab`, past the end of its lines) goes to a point on the page.
    static func widened(_ writing: BookWriting, to point: CGPoint, grab: CGFloat = 0) -> BookWriting {
        let local = writing.local(point)
        let width = min(max(local.x - grab + writing.width / 2, BookWriting.widths.lowerBound), BookWriting.widths.upperBound).rounded()
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
        // The handles of what's picked come first: its knob, a sticky note's corner, the bar at writing's side.
        if let handle = handle(at: point) {
            takeHold(of: handle, at: point)
            return
        }
        guard let hit = pagePoint(point) else {
            select(nil)
            // A closed cover's board, past its page, opens the book like the cover itself.
            if let forward = closedCoverOpens(at: point) { drag = .page(forward: forward, start: point, progress: 0, clickTurns: true) }
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
        if layout.pages[hit.page].holdsPhotos, let placement = layout.sticky(at: hit.point, onPage: hit.page), placement.id != turnedOver {
            if event.clickCount == 2 {
                delegate.bookWriteNote(placement.id, at: viewRect(of: placement.stickyCorners(), left: hit.left))
                return
            }
            pick(.sticky(placement.id))
            drag = .sticky(id: placement.id, page: hit.page, start: point, sticky: placement.sticky, moved: false)
            return
        }
        if layout.pages[hit.page].holdsPhotos, let placement = layout.placement(at: hit.point, onPage: hit.page) {
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
            drag = .photo(id: id, page: page, start: start, center: center, moved: true, turns: turns)
            // Lifted off the page as it starts to move, it can go to any page.
            if !moved, lift == nil { _ = liftPhoto(id, page: page, pointer: start) }
            if lift != nil {
                moveLift(to: point)
                return
            }
            let to = CGPoint(x: center.x + (point.x - start.x) * scale, y: center.y + (point.y - start.y) * scale)
            if turnedOver == id { setTurnedOver(nil) }
            delegate?.bookPreview(id, center: BookLayout.clamp(to), angle: nil)
            reloadPage(page)
        case let .writing(page, start, writing, moved):
            guard moved || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            drag = .writing(page: page, start: start, writing: writing, moved: true)
            delegate?.bookPreviewWriting(Self.moved(writing, by: CGPoint(x: (point.x - start.x) * scale, y: (point.y - start.y) * scale)), editing: nil)
            reloadPage(page)
            updateSelection()
        case let .widenWriting(page, writing, grab):
            delegate?.bookPreviewWriting(Self.widened(writing, to: pageCoordinates(point, onPage: page), grab: grab), editing: nil)
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
        case let .stretchSticky(id, page, sticky, grab):
            guard let placement = delegate?.layout.find(id)?.placement else { return }
            delegate?.bookPreviewSticky(id, Self.stretched(sticky, to: pageCoordinates(point, onPage: page), on: placement, grab: grab))
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
        case let .resize(id, page, start, grab):
            guard let frame = delegate?.layout.settings.frame else { return }
            let factor = start.resizeFactor(draggingCornerTo: pageCoordinates(point, onPage: page), grab: grab, frame: frame)
            delegate?.bookPreviewResize(id, from: start, factor: factor)
            reloadPage(page)
            updateSelection()
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
            if lift != nil {
                dropLift(at: point)
                return
            }
            let final = CGPoint(x: center.x + (point.x - start.x) * scale, y: center.y + (point.y - start.y) * scale)
            delegate?.bookCommit(id, center: BookLayout.clamp(final), angle: nil)
        case let .writing(_, start, writing, moved):
            guard moved else { return }
            delegate?.bookCommitWriting(Self.moved(writing, by: CGPoint(x: (point.x - start.x) * scale, y: (point.y - start.y) * scale)),
                                        actionName: "Move Writing")
        case let .widenWriting(page, writing, grab):
            delegate?.bookCommitWriting(Self.widened(writing, to: pageCoordinates(point, onPage: page), grab: grab), actionName: "Change Writing Width")
        case let .turnWriting(page, writing, startPointerAngle):
            delegate?.bookCommitWriting(Self.turned(writing, pointer: pageCoordinates(point, onPage: page), startPointerAngle: startPointerAngle,
                                                    snapping: event.modifierFlags.contains(.shift)), actionName: "Turn Writing")
        case let .sticky(id, _, start, sticky, moved):
            guard moved, let placement = delegate?.layout.find(id)?.placement else { return }
            delegate?.bookCommitSticky(id, Self.moved(sticky, by: CGPoint(x: (point.x - start.x) * scale, y: (point.y - start.y) * scale),
                                                      photoAngle: placement.angle), actionName: "Move Sticky Note")
        case let .stretchSticky(id, page, sticky, grab):
            guard let placement = delegate?.layout.find(id)?.placement else { return }
            delegate?.bookCommitSticky(id, Self.stretched(sticky, to: pageCoordinates(point, onPage: page), on: placement, grab: grab),
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
        case let .resize(id, page, start, grab):
            guard let frame = delegate?.layout.settings.frame else { return }
            delegate?.bookCommitResize(id, from: start,
                                       factor: start.resizeFactor(draggingCornerTo: pageCoordinates(point, onPage: page), grab: grab, frame: frame))
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
        guard !isTurning, let delegate, let hit = pagePoint(point) else {
            hover(nil)
            return
        }
        let placement = delegate.layout.pages[hit.page].holdsPhotos ? delegate.layout.placement(at: hit.point, onPage: hit.page) : nil
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
        for page in [pages.left, pages.right].compactMap({ $0 }) where delegate.layout.pages[page].holdsPhotos {
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

#if DEBUG
/// Where a book's handles take hold, painted in the book view's own coordinates over everything, for screenshots.
private final class HandleSpotsOverlay: NSView {
    var rects: [NSRect] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.35).setFill()
        for rect in rects { NSBezierPath(rect: rect).fill() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
