import AppKit
import PugglePhotosKit

/// A row of small thumbnails along the bottom of the viewer: the photos it steps through, with the one showing
/// ringed and kept in the middle. Click one to show it; scroll to look along the row. Only the thumbnails in view
/// exist, placed by arithmetic, so a row of thousands costs no more than a row of ten.
final class FilmstripView: NSView {
    static let height: CGFloat = 66
    private static let side: CGFloat = 44
    private static let spacing: CGFloat = 4

    /// Called when a thumbnail is clicked.
    var onChoose: ((PhotoID) -> Void)?
    weak var library: LibraryController?
    private(set) var ids: [PhotoID] = []
    /// Where the photo showing is in the row.
    private(set) var current: Int?
    private var positions: [PhotoID: Int] = [:]
    private let background = NSVisualEffectView()
    private let scrollView = SidewaysScrollView()
    private let row = FlippedView()
    /// The thumbnails in view, by place in the row, and ones scrolled away, kept to use again.
    private var cells: [Int: FilmstripCell] = [:]
    private var spare: [FilmstripCell] = []
    /// The width the ringed photo was last put in the middle for.
    private var centeredWidth: CGFloat = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        scrollView.documentView = row
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        for view in [background, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("Filmstrip")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Showing photos

    /// Shows a row of photos, if it's a different row, and rings the one showing.
    func show(_ ids: [PhotoID], current id: PhotoID?) {
        if ids != self.ids {
            self.ids = ids
            positions = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            current = nil
            for (index, cell) in cells { putAway(cell, index) }
            sizeRow()
        }
        select(id)
    }

    /// Rings a photo and slides the row to put it in the middle.
    func select(_ id: PhotoID?) {
        let index = id.flatMap { positions[$0] }
        let previous = current
        current = index
        if let previous { cells[previous]?.isCurrent = false }
        guard let index else { return }
        cells[index]?.isCurrent = true
        // A step to a photo nearby slides along; a jump far away, or Reduce Motion, goes straight there.
        let near = previous.map { abs($0 - index) <= 3 } ?? false
        center(index, animated: near && !Motion.isReduced && centeredWidth == bounds.width && bounds.width > 0)
    }

    private var step: CGFloat { Self.side + Self.spacing }

    /// Room at each end, so the first and last photos can sit in the middle too.
    private var inset: CGFloat { max(8, scrollView.contentSize.width / 2 - Self.side / 2) }

    private func frame(for index: Int) -> NSRect {
        NSRect(x: inset + CGFloat(index) * step, y: ((Self.height - Self.side) / 2).rounded(), width: Self.side, height: Self.side)
    }

    private func sizeRow() {
        let width = scrollView.contentSize.width
        let length = ids.isEmpty ? width : inset * 2 + CGFloat(ids.count) * step - Self.spacing
        row.frame = NSRect(x: 0, y: 0, width: max(length, width), height: Self.height)
        for (index, cell) in cells { cell.frame = frame(for: index) }
        tile()
    }

    /// Slides the row so a photo sits in the middle.
    private func center(_ index: Int, animated: Bool) {
        let point = NSPoint(x: max(0, frame(for: index).midX - scrollView.contentSize.width / 2), y: 0)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                scrollView.contentView.animator().setBoundsOrigin(point)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(point)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        tile()
    }

    /// Once the row knows its width (or the window changes size), it's laid out again with the ringed photo in the
    /// middle.
    override func layout() {
        super.layout()
        guard scrollView.contentSize.width > 0, bounds.width != centeredWidth else { return }
        centeredWidth = bounds.width
        sizeRow()
        if let current { center(current, animated: false) }
    }

    // MARK: Thumbnails

    @objc private func scrolled(_ note: Notification) { tile() }

    /// Puts thumbnails where the row is in view (and a little beyond), and puts away the ones scrolled off.
    private func tile() {
        guard let library, !ids.isEmpty else { return }
        let visible = scrollView.contentView.bounds.insetBy(dx: -step * 2, dy: 0)
        let first = max(0, Int(((visible.minX - inset) / step).rounded(.down)))
        let last = min(ids.count - 1, Int(((visible.maxX - inset) / step).rounded(.down)))
        let wanted = first <= last ? first...last : 0...(-1)
        for (index, cell) in cells where !wanted.contains(index) { putAway(cell, index) }
        let pixels = Self.side * (window?.backingScaleFactor ?? 2)
        for index in wanted where cells[index] == nil {
            let cell = spare.popLast() ?? FilmstripCell()
            if cell.superview == nil { row.addSubview(cell) }
            cell.isHidden = false
            cell.frame = frame(for: index)
            let id = ids[index]
            cell.show(id, isVideo: library.snapshot.item(id)?.kind.isVideo ?? false, spoken: library.spokenDescription(of: id),
                      thumbnails: library.thumbnails, pixels: pixels)
            cell.isCurrent = index == current
            cell.onClick = { [weak self] in self?.onChoose?(id) }
            cells[index] = cell
        }
    }

    private func putAway(_ cell: FilmstripCell, _ index: Int) {
        cell.clear()
        cell.isHidden = true
        cells[index] = nil
        spare.append(cell)
    }

    /// The photos with thumbnails in view, for the self-test.
    var visibleIDs: [PhotoID] { cells.keys.sorted().map { ids[$0] } }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Scrolls sideways with a mouse wheel as well as a trackpad.
final class SidewaysScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let origin = contentView.bounds.origin
        let widest = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        contentView.setBoundsOrigin(NSPoint(x: min(max(origin.x - event.scrollingDeltaY * 12, 0), widest), y: origin.y))
        reflectScrolledClipView(contentView)
    }
}

/// One small thumbnail in the filmstrip: dimmed, unless it's the photo showing, which is ringed. A video has a small
/// play mark.
final class FilmstripCell: NSView {
    private let imageLayer = CALayer()
    private let ring = CALayer()
    private let videoMark = CALayer()
    private var photoID: PhotoID?
    private var request: ImageRequest?
    var onClick: (() -> Void)?

    var isCurrent = false {
        didSet {
            ring.isHidden = !isCurrent
            imageLayer.opacity = isCurrent ? 1 : 0.62
            setAccessibilitySelected(isCurrent)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = 4
        imageLayer.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
        imageLayer.opacity = 0.62
        ring.borderWidth = 2.5
        ring.cornerRadius = 6
        ring.borderColor = Theme.accent.cgColor
        ring.isHidden = true
        videoMark.contents = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))?.tinted(.white)
        videoMark.contentsGravity = .center
        videoMark.shadowOpacity = 0.7
        videoMark.shadowRadius = 2
        videoMark.shadowOffset = .zero
        videoMark.isHidden = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(videoMark)
        layer?.addSublayer(ring)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds.insetBy(dx: 3, dy: 3)
        ring.frame = bounds
        videoMark.frame = NSRect(x: 6, y: bounds.height - 18, width: 12, height: 12)
        CATransaction.commit()
    }

    func show(_ id: PhotoID, isVideo: Bool, spoken: String, thumbnails: ThumbnailCache, pixels: CGFloat) {
        setAccessibilityLabel(spoken)
        videoMark.isHidden = !isVideo
        guard photoID != id else { return }
        request?.cancel()
        photoID = id
        setImage(thumbnails.cached(id, pixels: pixels))
        guard imageLayer.contents == nil else { return }
        request = thumbnails.request(id, pixels: pixels) { [weak self] image in
            guard let self, photoID == id else { return }
            setImage(image)
        }
    }

    func clear() {
        request?.cancel()
        request = nil
        photoID = nil
        setImage(nil)
        isCurrent = false
        onClick = nil
    }

    private func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
