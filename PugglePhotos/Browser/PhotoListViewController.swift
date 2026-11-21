import AppKit
import PugglePhotosKit

/// The list view: one row per photo with its title, date, kind, size, albums, labels and note, under the same
/// headings as the grid. Click a column heading to sort by title, date or kind.
final class PhotoListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: PhotoBrowserDelegate?
    /// Called when a column heading asks for a different sort.
    var onSort: ((SortKey, Bool) -> Void)?
    private(set) var tableView: PhotoTableView!
    private var rows: [Row] = []
    private var content = BrowserContent()
    private var isUpdatingSelection = false
    private var requests: [Int: ImageRequest] = [:]

    enum Row: Equatable {
        case header(Int)
        case item(PhotoID)
    }

    private enum Column: String, CaseIterable {
        case thumbnail, title, date, kind, size, albums, labels, note

        var title: String {
            switch self {
            case .thumbnail: ""
            case .title: "Title"
            case .date: "Date Taken"
            case .kind: "Kind"
            case .size: "Size"
            case .albums: "Albums"
            case .labels: "Labels"
            case .note: "Note"
            }
        }

        var width: CGFloat {
            switch self {
            case .thumbnail: 44
            case .title: 220
            case .date: 190
            case .kind: 90
            case .size: 110
            case .albums: 180
            case .labels: 160
            case .note: 260
            }
        }

        var sortKey: SortKey? {
            switch self {
            case .title: .title
            case .date: .dateTaken
            case .kind: .kind
            default: nil
            }
        }
    }

    override func loadView() {
        tableView = PhotoTableView()
        tableView.owner = self
        tableView.style = .inset
        tableView.rowHeight = 40
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(openClicked(_:))
        tableView.target = self
        tableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        tableView.setDraggingSourceOperationMask([], forLocal: false)
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .thumbnail ? 44 : 60
            if column == .thumbnail { tableColumn.maxWidth = 44 }
            if let key = column.sortKey {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            }
            tableView.addTableColumn(tableColumn)
        }
        tableView.setAccessibilityLabel("Photos")
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        view = scrollView
    }

    func show(_ content: BrowserContent, selecting selection: [PhotoID], sort: SortKey, ascending: Bool) {
        loadViewIfNeeded()
        self.content = content
        rows = []
        for (index, section) in content.sections.enumerated() {
            if content.showsHeaders { rows.append(.header(index)) }
            rows.append(contentsOf: section.items.map(Row.item))
        }
        requests.values.forEach { $0.cancel() }
        requests = [:]
        isUpdatingSelection = true
        // The table hears how many rows there are now before anything has it lay them out again (a new sort does), or
        // it asks about rows that are gone.
        tableView.reloadData()
        tableView.sortDescriptors = sort == .custom || sort == .dateAdded ? [] : [NSSortDescriptor(key: sort.rawValue, ascending: ascending)]
        select(selection, notify: false)
        isUpdatingSelection = false
    }

    func refreshVisible() {
        guard isViewLoaded else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    var selectedIDs: [PhotoID] {
        var seen = Set<PhotoID>()
        return tableView.selectedRowIndexes.compactMap { index -> PhotoID? in
            if case let .item(id) = rows[index] { return id }
            return nil
        }.filter { seen.insert($0).inserted }
    }

    func select(_ ids: [PhotoID], notify: Bool = true) {
        let wanted = Set(ids)
        let indexes = IndexSet(rows.indices.filter { if case let .item(id) = rows[$0] { wanted.contains(id) } else { false } })
        isUpdatingSelection = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { tableView.scrollRowToVisible(first) }
        isUpdatingSelection = false
        if notify { delegate?.browserSelectionDidChange(selectedIDs) }
    }

    @objc private func openClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0, case let .item(id) = rows[tableView.clickedRow] else { return }
        delegate?.browserOpen(id)
    }

    fileprivate func openSelection() {
        if let first = selectedIDs.first { delegate?.browserOpen(first) }
    }

    fileprivate func deleteSelection() { delegate?.browserDeleteSelection() }

    fileprivate func menu(forRow row: Int) -> NSMenu? {
        if row >= 0, !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        let ids = selectedIDs
        return ids.isEmpty ? nil : delegate?.browserMenu(for: ids)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 30 }
        return 40
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let library = delegate?.library else { return nil }
        switch rows[row] {
        case let .header(section):
            let field = NSTextField(labelWithString: "\(content.titles[section])   \(content.subtitles[section])")
            field.font = .systemFont(ofSize: 13, weight: .bold)
            return field
        case let .item(id):
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            if column == .thumbnail { return thumbnail(id, row: row, library: library) }
            let field = NSTextField(labelWithString: text(column, id, library))
            field.lineBreakMode = .byTruncatingTail
            field.textColor = column == .title ? .labelColor : .secondaryLabelColor
            if column == .title { field.font = .systemFont(ofSize: 13, weight: .medium) }
            return field
        }
    }

    private func thumbnail(_ id: PhotoID, row: Int, library: LibraryController) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let imageLayer = CALayer()
        imageLayer.frame = NSRect(x: 4, y: 4, width: 32, height: 32)
        imageLayer.cornerRadius = 4
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.backgroundColor = Theme.placeholder.cgColor
        view.layer?.addSublayer(imageLayer)
        let pixels = 32 * (self.view.window?.backingScaleFactor ?? 2)
        if let cached = library.thumbnails.cached(id, pixels: pixels) {
            imageLayer.contents = cached
        } else {
            requests[row]?.cancel()
            requests[row] = library.thumbnails.request(id, pixels: pixels) { image in
                imageLayer.contents = image
            }
        }
        return view
    }

    private func text(_ column: Column, _ id: PhotoID, _ library: LibraryController) -> String {
        let item = library.snapshot.item(id)
        let details: PhotoDetails? = library.details(id)
        switch column {
        case .thumbnail: return ""
        case .title:
            let title = library.title(of: id)
            return title.isEmpty ? "Untitled" : title
        case .date: return item.map { library.formatting.dateAndTime($0.date) } ?? ""
        case .kind:
            guard let item else { return "" }
            return item.kind.isVideo ? "Video, \(Formatting.duration(item.duration))" : item.kind.displayName
        case .size: return item.map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? ""
        case .albums:
            return library.membership.albums(containing: id).compactMap { library.catalog.album($0)?.title }.joined(separator: ", ")
        case .labels:
            return (details?.labels ?? []).compactMap { library.catalog.label($0)?.displayName }.joined(separator: ", ")
        case .note:
            return details?.note.replacingOccurrences(of: "\n", with: " ") ?? ""
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isUpdatingSelection { delegate?.browserSelectionDidChange(selectedIDs) }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isUpdatingSelection, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
              let sort = SortKey(rawValue: key) else { return }
        onSort?(sort, descriptor.ascending)
    }

    /// Photos of an album shared with you stay where they are: they aren't yours to put in albums.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        if case let .item(id) = rows[row], !SharedAlbum.isShared(id) { return PhotoDrag.item(id) }
        return nil
    }
}

final class PhotoTableView: NSTableView {
    fileprivate weak var owner: PhotoListViewController?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49: owner?.openSelection()
        case 51, 117: owner?.deleteSelection()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }
}
