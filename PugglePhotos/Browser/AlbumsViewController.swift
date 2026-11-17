import AppKit
import PugglePhotosKit

protocol AlbumsViewDelegate: AnyObject {
    var library: LibraryController { get }
    func albumsOpen(_ id: UUID)
    func albumsMenu(for id: UUID) -> NSMenu?
    func albumsNewAlbum()
    func albumsDrop(_ ids: [PhotoID], on album: UUID) -> Bool
}

/// Every album's cover, like prints stacked on a table: sorted by name, date, date created or size.
final class AlbumsViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewDelegateFlowLayout {
    weak var delegate: AlbumsViewDelegate?
    private(set) var collectionView: AlbumCollectionView!
    private(set) var summaries: [AlbumSummary] = []
    private let layout = NSCollectionViewFlowLayout()
    private var coverSide: CGFloat = 190

    override func loadView() {
        layout.minimumInteritemSpacing = 20
        layout.minimumLineSpacing = 26
        layout.sectionInset = NSEdgeInsets(top: 24, left: 26, bottom: 30, right: 26)
        collectionView = AlbumCollectionView()
        collectionView.owner = self
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [Theme.gridBackground]
        collectionView.register(AlbumCoverItem.self, forItemWithIdentifier: AlbumCoverItem.identifier)
        collectionView.registerForDraggedTypes([.photoID])
        collectionView.setAccessibilityLabel("Albums")
        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.gridBackground
        view = scrollView
    }

    func show(_ summaries: [AlbumSummary], thumbnailSide: CGFloat) {
        loadViewIfNeeded()
        self.summaries = summaries
        coverSide = max(140, min(300, thumbnailSide * 1.3))
        collectionView.reloadData()
    }

    func refreshVisible() {
        guard isViewLoaded else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            if let item = collectionView.item(at: indexPath) as? AlbumCoverItem { configure(item, at: indexPath) }
        }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { summaries.count + 1 }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: AlbumCoverItem.identifier, for: indexPath) as! AlbumCoverItem
        configure(item, at: indexPath)
        return item
    }

    private func configure(_ item: AlbumCoverItem, at indexPath: IndexPath) {
        guard let library = delegate?.library else { return }
        if indexPath.item == summaries.count {
            item.configureNewAlbum()
            return
        }
        let summary = summaries[indexPath.item]
        let dates = library.formatting.dateRange(from: summary.firstDate, to: summary.lastDate)
        let count = library.formatting.count(photos: summary.photos, videos: summary.videos)
        item.configure(summary, subtitle: [dates, count].compactMap { $0 }.joined(separator: " · "),
                       thumbnails: library.thumbnails, scale: view.window?.backingScaleFactor ?? 2)
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        NSSize(width: coverSide + 24, height: coverSide + 74)
    }

    fileprivate func open(at point: NSPoint) {
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        if indexPath.item == summaries.count { delegate?.albumsNewAlbum() } else { delegate?.albumsOpen(summaries[indexPath.item].id) }
    }

    fileprivate func openSelection() {
        guard let indexPath = collectionView.selectionIndexPaths.first else { return }
        if indexPath.item == summaries.count { delegate?.albumsNewAlbum() } else { delegate?.albumsOpen(summaries[indexPath.item].id) }
    }

    fileprivate func menu(at point: NSPoint) -> NSMenu? {
        guard let indexPath = collectionView.indexPathForItem(at: point), indexPath.item < summaries.count else { return nil }
        collectionView.selectionIndexPaths = [indexPath]
        return delegate?.albumsMenu(for: summaries[indexPath.item].id)
    }

    var selectedAlbum: UUID? {
        guard let indexPath = collectionView.selectionIndexPaths.first, indexPath.item < summaries.count else { return nil }
        return summaries[indexPath.item].id
    }

    // Dropping photos on a cover adds them to that album.

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let indexPath = proposedDropIndexPath.pointee as IndexPath
        guard proposedDropOperation.pointee == .on, indexPath.item < summaries.count,
              !PhotoDrag.ids(from: draggingInfo.draggingPasteboard).isEmpty else { return [] }
        return .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard indexPath.item < summaries.count else { return false }
        return delegate?.albumsDrop(PhotoDrag.ids(from: draggingInfo.draggingPasteboard), on: summaries[indexPath.item].id) ?? false
    }
}

final class AlbumCollectionView: NSCollectionView {
    fileprivate weak var owner: AlbumsViewController?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { owner?.open(at: convert(event.locationInWindow, from: nil)) }
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode) { owner?.openSelection() } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(at: convert(event.locationInWindow, from: nil))
    }
}

/// One album cover: the cover photo on a white print, with two more prints peeking out behind it.
final class AlbumCoverItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AlbumCoverItem")
    private var request: ImageRequest?
    private var albumID: UUID?
    private var coverView: AlbumCoverView { view as! AlbumCoverView }

    override func loadView() { view = AlbumCoverView() }

    override var isSelected: Bool { didSet { coverView.isSelected = isSelected } }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { coverView.isDropTarget = highlightState == .asDropTarget }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        request?.cancel()
        request = nil
        albumID = nil
        coverView.image = nil
    }

    func configure(_ summary: AlbumSummary, subtitle: String, thumbnails: ThumbnailCache, scale: CGFloat) {
        coverView.isNewAlbum = false
        coverView.title = summary.title
        coverView.subtitle = subtitle
        coverView.setAccessibilityLabel("\(summary.title), \(subtitle)")
        let sameAlbum = albumID == summary.id
        albumID = summary.id
        guard let cover = summary.cover else {
            coverView.image = nil
            return
        }
        let pixels = 320 * scale
        if let cached = thumbnails.cached(cover, pixels: pixels) {
            coverView.image = cached
            return
        }
        if !sameAlbum { coverView.image = nil }
        request?.cancel()
        let id = summary.id
        request = thumbnails.request(cover, pixels: pixels) { [weak self] image in
            guard let self, albumID == id else { return }
            coverView.image = image
        }
    }

    func configureNewAlbum() {
        albumID = nil
        coverView.image = nil
        coverView.isNewAlbum = true
        coverView.title = "New Album"
        coverView.subtitle = ""
        coverView.setAccessibilityLabel("New Album")
    }
}

final class AlbumCoverView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isDropTarget = false { didSet { needsDisplay = true } }
    var isNewAlbum = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let side = bounds.width - 24
        let print = NSRect(x: 12, y: 8, width: side, height: side)
        if isNewAlbum {
            let path = NSBezierPath(roundedRect: print.insetBy(dx: 10, dy: 10), xRadius: 14, yRadius: 14)
            path.lineWidth = 2
            path.setLineDash([8, 6], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 34, weight: .medium))
            if let plus {
                let tinted = plus.tinted(.secondaryLabelColor)
                tinted.draw(in: NSRect(x: print.midX - tinted.size.width / 2, y: print.midY - tinted.size.height / 2,
                                       width: tinted.size.width, height: tinted.size.height))
            }
        } else {
            // Two prints behind, turned a little, then the cover print.
            for (angle, offset) in [(-5.0, NSPoint(x: -4, y: 2)), (4.0, NSPoint(x: 4, y: 0))] {
                drawPrint(in: print.offsetBy(dx: offset.x, dy: offset.y), angle: angle, image: nil)
            }
            drawPrint(in: print, angle: 0, image: image)
        }
        if isSelected || isDropTarget {
            let ring = NSBezierPath(roundedRect: print.insetBy(dx: -5, dy: -5), xRadius: 8, yRadius: 8)
            ring.lineWidth = 3
            Theme.accent.setStroke()
            ring.stroke()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 4, y: print.maxY + 12, width: bounds.width - 8, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        (subtitle as NSString).draw(in: NSRect(x: 4, y: print.maxY + 31, width: bounds.width - 8, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ])
    }

    private func drawPrint(in rect: NSRect, angle: CGFloat, image: CGImage?) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        transform.concat()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        Theme.paper.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard angle == 0 else { return }
        let photo = rect.insetBy(dx: 8, dy: 8)
        if let image, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.addPath(CGPath(roundedRect: photo, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.clip()
            // Fill the square, cropping the longer side, and flip back to draw upright.
            let scale = max(photo.width / CGFloat(image.width), photo.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.translateBy(x: photo.midX, y: photo.midY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        } else {
            Theme.placeholder.setFill()
            NSBezierPath(roundedRect: photo, xRadius: 2, yRadius: 2).fill()
            if let symbol = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 30, weight: .regular))?.tinted(.tertiaryLabelColor) {
                symbol.draw(in: NSRect(x: photo.midX - symbol.size.width / 2, y: photo.midY - symbol.size.height / 2,
                                       width: symbol.size.width, height: symbol.size.height))
            }
        }
    }
}

extension NSImage {
    /// A copy of a template image in one color.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
