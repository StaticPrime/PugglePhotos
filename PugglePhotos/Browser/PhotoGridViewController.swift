import AppKit
import PugglePhotosKit

/// What a photo list (the grid or the list) shows.
struct BrowserContent {
    var sections: [PhotoSection] = []
    var titles: [String] = []
    var subtitles: [String] = []
    var drops: [HeaderDrop?] = []
    /// What the journal says about each section's day ("" for none), with its mood.
    var journal: [String] = []
    var showsHeaders = false
    /// The album shown, for its banner.
    var album: Album?
    var albumSubtitle = ""
    /// Whether photos can be dropped between others: in date order to change their dates, or in an album's own
    /// order to move them.
    var dropsBetween = false

    var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }
    var allIDs: [PhotoID] { sections.flatMap(\.items) }

    func id(at indexPath: IndexPath) -> PhotoID? {
        guard sections.indices.contains(indexPath.section), sections[indexPath.section].items.indices.contains(indexPath.item) else { return nil }
        return sections[indexPath.section].items[indexPath.item]
    }

    /// Every place a photo shows (more than one when it's in several albums and the view groups by album).
    func indexPaths(of ids: Set<PhotoID>) -> Set<IndexPath> {
        var result = Set<IndexPath>()
        for (section, content) in sections.enumerated() {
            for (item, id) in content.items.enumerated() where ids.contains(id) {
                result.insert(IndexPath(item: item, section: section))
            }
        }
        return result
    }
}

/// What the grid and the list ask of the window.
protocol PhotoBrowserDelegate: AnyObject {
    var library: LibraryController { get }
    func browserSelectionDidChange(_ ids: [PhotoID])
    func browserOpen(_ id: PhotoID)
    func browserMenu(for ids: [PhotoID]) -> NSMenu?
    func browserDeleteSelection()
    /// Photos dropped in the gap before `indexPath` (an item index equal to the section's count is the end).
    func browserDrop(_ ids: [PhotoID], before indexPath: IndexPath, anchor: NSRect, in view: NSView) -> Bool
    func browserHeaderDrop(_ ids: [PhotoID], _ drop: HeaderDrop, anchor: NSView) -> Bool
    func browserRenameAlbum(_ title: String)
    func browserSetAlbumNote(_ note: String)
    func browserPlayAlbum()
    func browserOpenBook()
    /// Write in the journal about a day, from its heading.
    func browserWriteJournal(for day: CivilDay, anchor: NSView)
    /// Write on the back of a photo turned over in the grid.
    func browserWriteNote(for id: PhotoID, anchor: NSView)
}

/// The photo grid: thumbnails in sections, chosen, opened, dragged and dropped like files in a folder.
final class PhotoGridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    weak var delegate: PhotoBrowserDelegate?
    let layout = PhotoGridLayout()
    private(set) var collectionView: PhotoCollectionView!
    private var scrollView: NSScrollView!
    private(set) var content = BrowserContent()
    private var isUpdatingSelection = false
    private var draggedIDs: [PhotoID] = []

    var thumbnailSide: CGFloat {
        get { layout.targetSide }
        set { layout.targetSide = newValue }
    }

    override func loadView() {
        collectionView = PhotoCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [Theme.gridBackground]
        collectionView.register(PhotoCell.self, forItemWithIdentifier: PhotoCell.identifier)
        collectionView.register(SectionHeaderView.self, forSupplementaryViewOfKind: PhotoGridLayout.headerKind,
                                withIdentifier: SectionHeaderView.identifier)
        collectionView.register(AlbumBannerView.self, forSupplementaryViewOfKind: PhotoGridLayout.bannerKind,
                                withIdentifier: AlbumBannerView.identifier)
        collectionView.registerForDraggedTypes([.photoID])
        collectionView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        collectionView.setDraggingSourceOperationMask([], forLocal: false)
        collectionView.owner = self
        collectionView.setAccessibilityLabel("Photos")
        scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.gridBackground
        view = scrollView
    }

    // MARK: Content

    /// Shows new content, keeping the selection and what's on screen where possible.
    func show(_ content: BrowserContent, selecting selection: [PhotoID], keepPosition: Bool) {
        loadViewIfNeeded()
        let anchor = keepPosition ? firstVisibleID() : nil
        self.content = content
        layout.headerHeight = content.showsHeaders ? 46 : 0
        var notes: [Int: String] = [:]
        for (section, note) in content.journal.enumerated() where !note.isEmpty { notes[section] = note }
        layout.notes = notes
        let width = scrollView.contentSize.width
        layout.bannerHeight = content.album.map { AlbumBannerView.height(note: $0.note, width: width) } ?? 0
        isUpdatingSelection = true
        collectionView.reloadData()
        collectionView.selectionIndexPaths = content.indexPaths(of: Set(selection))
        isUpdatingSelection = false
        if let turned = turnedOver, content.indexPaths(of: [turned]).isEmpty { turnedOver = nil }
        if let anchor { scroll(to: anchor, animated: false) } else if !keepPosition { scrollToStart() }
        resetPrefetch()
        DispatchQueue.main.async { [weak self] in self?.updatePrefetch() }
    }

    // MARK: Getting thumbnails ready ahead

    /// The photos whose thumbnails are being got ready, and where the view was when they were chosen.
    private(set) var prefetched: Set<PhotoID> = []
    private var prefetchedRect = NSRect.zero
    private var prefetchedPixels: CGFloat = 0

    @objc private func scrolled(_ note: Notification) { updatePrefetch() }

    /// Gets thumbnails ready a screen above and below what's showing, checked again each third of a screen scrolled.
    func updatePrefetch() {
        guard let library = delegate?.library, view.window != nil else { return }
        let visible = collectionView.visibleRect
        guard visible.height > 0 else { return }
        let pixels = layout.side * (view.window?.backingScaleFactor ?? 2)
        if pixels == prefetchedPixels, abs(visible.midY - prefetchedRect.midY) < visible.height / 3 { return }
        if pixels != prefetchedPixels { resetPrefetch() }
        let band = visible.insetBy(dx: 0, dy: -visible.height)
        let ids = Set(layout.layoutAttributesForElements(in: band).filter { $0.representedElementCategory == .item }
            .compactMap { $0.indexPath.flatMap(content.id(at:)) })
        library.thumbnails.prefetch(start: Array(ids.subtracting(prefetched)), stop: Array(prefetched.subtracting(ids)), pixels: pixels)
        prefetched = ids
        prefetchedRect = visible
        prefetchedPixels = pixels
    }

    private func resetPrefetch() {
        if !prefetched.isEmpty { delegate?.library.thumbnails.stopPrefetching() }
        prefetched = []
        prefetchedRect = .zero
        prefetchedPixels = 0
    }

    /// Redraws the visible thumbnails' badges and the headings without reloading.
    func refreshVisible() {
        guard isViewLoaded else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            if let cell = collectionView.item(at: indexPath) as? PhotoCell { configure(cell, at: indexPath) }
        }
    }

    func scrollToStart() {
        collectionView.scroll(.zero)
    }

    /// Scrolls to the last photos. The whole window is laid out first, so the grid knows its real height.
    func scrollToEnd() {
        view.window?.layoutIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
        let height = layout.collectionViewContentSize.height
        collectionView.scrollToVisible(NSRect(x: 0, y: max(0, height - 2), width: 1, height: 2))
    }

    /// Scrolls so the photo is in view.
    func scroll(to id: PhotoID, animated: Bool = true) {
        guard let indexPath = content.indexPaths(of: [id]).min() else { return }
        collectionView.layoutSubtreeIfNeeded()
        var frame = layout.frameForItem(at: indexPath)
        let heading = layout.headerHeight(indexPath.section)
        frame.origin.y -= heading + 8
        frame.size.height += heading + 16
        if animated { collectionView.animator().scrollToVisible(frame) } else { collectionView.scrollToVisible(frame) }
    }

    /// Scrolls a section's heading to the top.
    func scroll(toSection section: Int) {
        guard content.sections.indices.contains(section) else { return }
        collectionView.layoutSubtreeIfNeeded()
        let frame = layout.frameForItem(at: IndexPath(item: 0, section: section))
        collectionView.scroll(NSPoint(x: 0, y: max(0, frame.minY - layout.headerHeight(section) - layout.sectionGap / 2)))
    }

    /// The first photo fully below the pinned heading, worked out from the layout (the collection view's own list
    /// of visible items can lag behind a scroll it hasn't drawn yet).
    func firstVisibleID() -> PhotoID? {
        let visible = collectionView.visibleRect
        guard visible.height > 0 else { return nil }
        let paths = layout.layoutAttributesForElements(in: visible)
            .filter { $0.representedElementCategory == .item }.compactMap(\.indexPath).sorted()
        return paths.first { layout.frameForItem(at: $0).minY >= visible.minY + layout.headerHeight($0.section) - 4 }.flatMap(content.id(at:))
            ?? paths.first.flatMap(content.id(at:))
    }

    var selectedIDs: [PhotoID] {
        var seen = Set<PhotoID>()
        return collectionView.selectionIndexPaths.sorted().compactMap(content.id(at:)).filter { seen.insert($0).inserted }
    }

    func select(_ ids: [PhotoID]) {
        isUpdatingSelection = true
        collectionView.selectionIndexPaths = content.indexPaths(of: Set(ids))
        isUpdatingSelection = false
        delegate?.browserSelectionDidChange(selectedIDs)
    }

    func selectSection(_ section: Int, extend: Bool) {
        guard content.sections.indices.contains(section) else { return }
        let paths = Set(content.sections[section].items.indices.map { IndexPath(item: $0, section: section) })
        collectionView.selectionIndexPaths = extend ? collectionView.selectionIndexPaths.union(paths) : paths
        delegate?.browserSelectionDidChange(selectedIDs)
        view.window?.makeFirstResponder(collectionView)
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { content.sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        content.sections[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: PhotoCell.identifier, for: indexPath) as! PhotoCell
        configure(cell, at: indexPath)
        return cell
    }

    private func configure(_ cell: PhotoCell, at indexPath: IndexPath) {
        guard let id = content.id(at: indexPath), let library = delegate?.library else { return }
        cell.configure(id, badges: Self.badges(id, library), title: library.title(of: id), spoken: library.spokenDescription(of: id),
                       thumbnails: library.thumbnails, side: layout.side, scale: view.window?.backingScaleFactor ?? 2)
        let over = turnedOver == id
        cell.turnOver(over, back: over ? backImage(id) : nil, animated: false)
    }

    // MARK: Turning photos over

    /// The photo turned over to show its back, if any: one at a time.
    private(set) var turnedOver: PhotoID?

    /// Turns a photo over (and the one turned over before, back), or with nil, turns it back.
    func turnOver(_ id: PhotoID?, animated: Bool = true) {
        let previous = turnedOver
        turnedOver = id
        for changed in Set([previous, id].compactMap { $0 }) {
            for indexPath in content.indexPaths(of: [changed]) {
                guard let cell = collectionView.item(at: indexPath) as? PhotoCell else { continue }
                cell.turnOver(changed == id, back: changed == id ? backImage(changed) : nil, animated: animated)
            }
        }
    }

    /// A photo's back at the size the grid shows it.
    private func backImage(_ id: PhotoID) -> CGImage? {
        guard let library = delegate?.library else { return nil }
        return PhotoBack.image(PhotoBack.content(of: id, library: library), size: CGSize(width: layout.side, height: layout.side),
                               scale: view.window?.backingScaleFactor ?? 2)
    }

    /// The thumbnail showing a photo, if it's on screen.
    func cellView(for id: PhotoID) -> NSView? {
        content.indexPaths(of: [id]).sorted().lazy.compactMap { self.collectionView.item(at: $0)?.view }.first
    }

    /// Whether the photo at a point is the one photo chosen, so a click on it turns it over rather than choosing it.
    fileprivate func isOnlyChoice(at point: NSPoint) -> Bool {
        guard let indexPath = collectionView.indexPathForItem(at: point), let id = content.id(at: indexPath) else { return false }
        return selectedIDs == [id]
    }

    /// A plain click: the first on a photo chooses it; one on the photo already chosen turns it over, or back. A
    /// click anywhere else turns any photo back.
    fileprivate func clicked(at point: NSPoint, wasChosen: Bool) {
        guard let indexPath = collectionView.indexPathForItem(at: point), let id = content.id(at: indexPath) else {
            turnOver(nil)
            return
        }
        guard wasChosen, Preferences.flipsOnClick else { return }
        turnOver(turnedOver == id ? nil : id)
    }

    /// A click on the pencil on a turned-over photo's back writes on it.
    fileprivate func pencil(at point: NSPoint) -> Bool {
        guard let id = turnedOver, let indexPath = collectionView.indexPathForItem(at: point), content.id(at: indexPath) == id,
              let cell = collectionView.item(at: indexPath) else { return false }
        let local = cell.view.convert(point, from: collectionView)
        guard PhotoBack.pencilRect(in: cell.view.bounds.size).contains(local) else { return false }
        delegate?.browserWriteNote(for: id, anchor: cell.view)
        return true
    }

    /// What a thumbnail shows over the photo. With badges turned off in Settings, only a video's length stays.
    static func badges(_ id: PhotoID, _ library: LibraryController) -> CellBadges {
        let item = library.snapshot.item(id)
        guard UserDefaults.standard.bool(forKey: Preferences.showsBadgesKey) else {
            return CellBadges(isVideo: item?.kind.isVideo ?? false, duration: item?.duration ?? 0, kind: item?.kind ?? .photo)
        }
        let details = library.catalog.photos[id]
        return CellBadges(isFavorite: item?.isFavorite ?? false, isVideo: item?.kind.isVideo ?? false,
                          duration: item?.duration ?? 0, kind: item?.kind ?? .photo,
                          labelColors: (details?.labels ?? []).compactMap { library.catalog.label($0)?.color },
                          hasNote: !(details?.note.isEmpty ?? true))
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        if kind == PhotoGridLayout.bannerKind {
            let banner = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: AlbumBannerView.identifier, for: indexPath) as! AlbumBannerView
            if let album = content.album {
                banner.configure(title: album.title, subtitle: content.albumSubtitle, note: album.note)
            }
            banner.onRename = { [weak self] in self?.delegate?.browserRenameAlbum($0) }
            banner.onNote = { [weak self] in self?.delegate?.browserSetAlbumNote($0) }
            banner.onPlay = { [weak self] in self?.delegate?.browserPlayAlbum() }
            banner.onOpenBook = { [weak self] in self?.delegate?.browserOpenBook() }
            return banner
        }
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeaderView.identifier, for: indexPath) as! SectionHeaderView
        let section = indexPath.section
        if content.titles.indices.contains(section) {
            header.configure(title: content.titles[section], subtitle: content.subtitles[section], section: section,
                             drop: content.drops.indices.contains(section) ? content.drops[section] : nil,
                             journal: content.journal.indices.contains(section) ? content.journal[section] : nil)
        }
        header.onSelect = { [weak self] section, extend in self?.selectSection(section, extend: extend) }
        header.onWrite = { [weak self] day, view in self?.delegate?.browserWriteJournal(for: day, anchor: view) }
        header.onDrop = { [weak self] ids, drop, view in self?.delegate?.browserHeaderDrop(ids, drop, anchor: view) ?? false }
        return header
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if !isUpdatingSelection { delegate?.browserSelectionDidChange(selectedIDs) }
        turnBackUnlessSelected()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if !isUpdatingSelection { delegate?.browserSelectionDidChange(selectedIDs) }
        turnBackUnlessSelected()
    }

    /// A photo turned over goes back once it's no longer the one chosen.
    private func turnBackUnlessSelected() {
        if let turned = turnedOver, !selectedIDs.contains(turned) { turnOver(nil) }
    }

    // MARK: Dragging

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        content.id(at: indexPath).map(PhotoDrag.item)
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                        forItemsAt indexPaths: Set<IndexPath>) {
        draggedIDs = indexPaths.sorted().compactMap(content.id(at:))
        (collectionView as? PhotoCollectionView)?.pendingClick = nil
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                        dragOperation operation: NSDragOperation) {
        draggedIDs = []
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard content.dropsBetween, !PhotoDrag.ids(from: draggingInfo.draggingPasteboard).isEmpty else { return [] }
        proposedDropOperation.pointee = .before
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        let ids = PhotoDrag.ids(from: draggingInfo.draggingPasteboard)
        guard !ids.isEmpty, let delegate else { return false }
        let gap = layout.layoutAttributesForInterItemGap(before: indexPath)?.frame ?? NSRect(origin: draggingInfo.draggingLocation, size: .zero)
        return delegate.browserDrop(ids, before: indexPath, anchor: gap, in: collectionView)
    }

    // MARK: Actions from the collection view

    fileprivate func openSelection() {
        guard let first = collectionView.selectionIndexPaths.min().flatMap(content.id(at:)) else { return }
        delegate?.browserOpen(first)
    }

    fileprivate func openItem(at point: NSPoint) {
        guard let indexPath = collectionView.indexPathForItem(at: point), let id = content.id(at: indexPath) else { return }
        turnOver(nil, animated: false)
        delegate?.browserOpen(id)
    }

    fileprivate func menu(at point: NSPoint) -> NSMenu? {
        if let indexPath = collectionView.indexPathForItem(at: point), !collectionView.selectionIndexPaths.contains(indexPath) {
            collectionView.selectionIndexPaths = [indexPath]
            delegate?.browserSelectionDidChange(selectedIDs)
        }
        let ids = selectedIDs
        return ids.isEmpty ? nil : delegate?.browserMenu(for: ids)
    }

    fileprivate func deleteSelection() { delegate?.browserDeleteSelection() }
}

/// The grid's collection view, with double-click and Return to open, Delete to remove from an album, and a
/// context menu for what's selected.
final class PhotoCollectionView: NSCollectionView {
    fileprivate weak var owner: PhotoGridViewController?

    /// Where a plain click began, and whether its photo was already the one chosen, until it ends as a click (or
    /// turns into a drag).
    fileprivate var pendingClick: (point: NSPoint, wasChosen: Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            pendingClick = nil
            owner?.openItem(at: point)
            return
        }
        if owner?.pencil(at: point) == true { return }
        let plain = event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty
        pendingClick = plain && event.clickCount == 1 ? (point, owner?.isOnlyChoice(at: point) ?? false) : nil
        super.mouseDown(with: event)
        // The collection view may follow the mouse until it's let go, in which case that was the click.
        if let current = NSApp.currentEvent, current.type == .leftMouseUp { finishClick(current) }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        finishClick(event)
    }

    /// A plain click that didn't move: on the photo already chosen, it turns it over (or back).
    private func finishClick(_ event: NSEvent) {
        guard let start = pendingClick else { return }
        pendingClick = nil
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.point.x, point.y - start.point.y) < 5 else { return }
        owner?.clicked(at: point, wasChosen: start.wasChosen)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49: // Return, Enter, Space
            owner?.openSelection()
        case 51, 117: // Delete, Forward Delete
            owner?.deleteSelection()
        case 53 where owner?.turnedOver != nil: // Esc turns a photo back
            owner?.turnOver(nil)
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(at: convert(event.locationInWindow, from: nil))
    }

    override var acceptsFirstResponder: Bool { true }
}
