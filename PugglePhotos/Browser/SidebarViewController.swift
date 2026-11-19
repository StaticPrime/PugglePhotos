import AppKit
import PugglePhotosKit

protocol SidebarDelegate: AnyObject {
    var library: LibraryController { get }
    var sharing: SharingController { get }
    /// How many years today's memories come from, for the Memories row.
    var memoriesToday: Int { get }
    var albumOrder: [UUID] { get }
    func sidebarSelect(_ source: LibrarySource)
    func sidebarNewAlbum()
    func sidebarNewSharedAlbum()
    func sidebarNewLabel()
    func sidebarMenu(for source: LibrarySource) -> NSMenu?
    func sidebarRenameAlbum(_ id: UUID, to title: String)
    func sidebarDrop(_ ids: [PhotoID], on source: LibrarySource) -> Bool
    func sidebarDropOnAlbumsHeading(_ ids: [PhotoID]) -> Bool
    /// Photos and videos dropped from another app, on a row they can go to.
    func sidebarDropFiles(_ urls: [URL], on target: FileDropTarget)
    func calendarSelect(_ day: CivilDay)
    func calendarDrop(_ ids: [PhotoID], on day: CivilDay, rect: NSRect, in view: NSView) -> Bool
}

/// A row in the sidebar. Nodes are classes because the outline view tells rows apart by identity.
final class SidebarNode {
    enum Kind: Hashable {
        case heading(String)
        case source(LibrarySource)
    }

    let kind: Kind
    var children: [SidebarNode]

    init(_ kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind
        self.children = children
    }

    var source: LibrarySource? {
        if case let .source(source) = kind { return source }
        return nil
    }
}

/// The sidebar: the library, albums and labels, with the calendar underneath.
/// Drop photos on an album, a label or Favorites to add them there. Photos and videos dragged in from other apps
/// can be dropped there too, or on Library, Videos or Recently Added, and go into the library as well.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    weak var delegate: SidebarDelegate?
    private(set) var outlineView: NSOutlineView!
    private(set) var calendar: MiniCalendarView!
    private var calendarContainer: NSView!
    private var roots: [SidebarNode] = []
    private var isReloading = false
    /// Where the collapsed headings are remembered.
    var defaults = UserDefaults.standard {
        didSet { collapsed = Set(defaults.stringArray(forKey: "SidebarCollapsed") ?? []) }
    }
    private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "SidebarCollapsed") ?? [])
    private var requests: [UUID: ImageRequest] = [:]
    private(set) var selectedSource: LibrarySource?

    private var calendarHeight: NSLayoutConstraint?

    var showsCalendar = true {
        didSet {
            calendarContainer?.isHidden = !showsCalendar
            calendarHeight?.constant = showsCalendar ? MiniCalendarView.height + 11 : 0
        }
    }

    override func loadView() {
        outlineView = NSOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = 0
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([.photoID] + FileDrop.types)
        outlineView.draggingDestinationFeedbackStyle = .sourceList
        outlineView.autosaveExpandedItems = false
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.setAccessibilityLabel("Sidebar")
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        calendar = MiniCalendarView(today: CivilDay(Date(), in: .current))
        calendar.translatesAutoresizingMaskIntoConstraints = false
        calendar.onSelectDay = { [weak self] day in self?.delegate?.calendarSelect(day) }
        calendar.onDrop = { [weak self] ids, day, rect in
            guard let self, let delegate else { return false }
            return delegate.calendarDrop(ids, on: day, rect: rect, in: calendar)
        }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        calendarContainer = NSView()
        calendarContainer.translatesAutoresizingMaskIntoConstraints = false
        calendarContainer.addSubview(separator)
        calendarContainer.addSubview(calendar)

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(calendarContainer)
        let height = calendarContainer.heightAnchor.constraint(equalToConstant: MiniCalendarView.height + 11)
        calendarHeight = height
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: calendarContainer.topAnchor),
            calendarContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            calendarContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            calendarContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            height,
            separator.leadingAnchor.constraint(equalTo: calendarContainer.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: calendarContainer.trailingAnchor, constant: -10),
            separator.topAnchor.constraint(equalTo: calendarContainer.topAnchor),
            calendar.leadingAnchor.constraint(equalTo: calendarContainer.leadingAnchor, constant: 4),
            calendar.trailingAnchor.constraint(equalTo: calendarContainer.trailingAnchor, constant: -4),
            calendar.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            calendar.heightAnchor.constraint(equalToConstant: MiniCalendarView.height),
        ])
        view = root
    }

    // MARK: Contents

    /// Rebuilds the rows from the library and catalog, keeping the selection.
    func reload() {
        guard let library = delegate?.library else { return }
        let libraryNodes: [SidebarNode] = [.memories, .journal, .library, .favorites, .videos, .map, .recentlyAdded].map { SidebarNode(.source($0)) }
        var albumNodes = [SidebarNode(.source(.allAlbums))]
        albumNodes += (delegate?.albumOrder ?? library.catalog.albums.map(\.id)).map { SidebarNode(.source(.album($0))) }
        let labelNodes = library.catalog.labels.map { SidebarNode(.source(.label($0.id))) }
        // Albums you share, then albums shared with you, each by name.
        let sharing = delegate?.sharing
        let yours = (sharing?.mine ?? []).filter { library.catalog.album($0.id) != nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map { SidebarNode(.source(.album($0.id))) }
        let theirs = (sharing?.sharedWithMe ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { SidebarNode(.source(.sharedAlbum($0.id))) }
        roots = [SidebarNode(.heading("Library"), children: libraryNodes), SidebarNode(.heading("Albums"), children: albumNodes),
                 SidebarNode(.heading("Shared Albums"), children: yours + theirs), SidebarNode(.heading("Labels"), children: labelNodes)]
        isReloading = true
        outlineView.reloadData()
        for root in roots {
            if case let .heading(title) = root.kind, collapsed.contains(title) {
                outlineView.collapseItem(root)
            } else {
                outlineView.expandItem(root)
            }
        }
        if let selectedSource { select(selectedSource) }
        isReloading = false
        calendar.counts = library.snapshot.countsByDay()
        calendar.years = Array(Set(calendar.counts.keys.map(\.year)))
        calendar.formatting = library.formatting
        calendar.today = CivilDay(Date(), in: library.formatting.timeZone)
    }

    /// Redraws counts and covers without rebuilding.
    func refreshRows() {
        let rows = outlineView.numberOfRows
        guard rows > 0 else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows), columnIndexes: [0])
    }

    func select(_ source: LibrarySource) {
        selectedSource = source
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? SidebarNode, node.source == source {
                if outlineView.selectedRow != row {
                    let wasReloading = isReloading
                    isReloading = true
                    outlineView.selectRowIndexes([row], byExtendingSelection: false)
                    isReloading = wasReloading
                }
                outlineView.scrollRowToVisible(row)
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    /// Starts renaming an album where it is in the sidebar.
    func beginRenaming(_ album: UUID) {
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? SidebarNode, node.source == .album(album),
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else { continue }
            outlineView.scrollRowToVisible(row)
            cell.textField?.isEditable = true
            cell.textField?.delegate = self
            view.window?.makeFirstResponder(cell.textField)
            cell.textField?.currentEditor()?.selectAll(nil)
            return
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode, case let .album(id)? = node.source else { return }
        beginRenaming(id)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        field.isEditable = false
        let row = outlineView.row(for: field)
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode, case let .album(id)? = node.source else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == delegate?.library.catalog.album(id)?.title {
            field.stringValue = delegate?.library.catalog.album(id)?.title ?? ""
        } else {
            delegate?.sidebarRenameAlbum(id, to: title)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField {
            let row = outlineView.row(for: field)
            if let node = outlineView.item(atRow: row) as? SidebarNode, case let .album(id)? = node.source {
                field.stringValue = delegate?.library.catalog.album(id)?.title ?? ""
            }
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }

    // MARK: Outline view

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .heading = (item as? SidebarNode)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .heading = (item as? SidebarNode)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.source != nil
    }

    func outlineViewItemDidCollapse(_ notification: Notification) { rememberExpansion(notification, collapsed: true) }
    func outlineViewItemDidExpand(_ notification: Notification) { rememberExpansion(notification, collapsed: false) }

    /// Remembers a heading the person opened or closed with a click or a key, never one closed along the way.
    private func rememberExpansion(_ notification: Notification, collapsed isCollapsed: Bool) {
        guard !isReloading, let node = notification.userInfo?["NSObject"] as? SidebarNode, case let .heading(title) = node.kind,
              let event = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown, .keyDown].contains(event.type) else { return }
        if isCollapsed { collapsed.insert(title) } else { collapsed.remove(title) }
        defaults.set(Array(collapsed), forKey: "SidebarCollapsed")
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode, let library = delegate?.library else { return nil }
        switch node.kind {
        case let .heading(title):
            let cell = outlineView.makeView(withIdentifier: SidebarHeadingCell.identifier, owner: self) as? SidebarHeadingCell ?? SidebarHeadingCell()
            let add: (() -> Void)? = switch title {
            case "Albums": { [weak self] in self?.delegate?.sidebarNewAlbum() }
            case "Shared Albums": { [weak self] in self?.delegate?.sidebarNewSharedAlbum() }
            case "Labels": { [weak self] in self?.delegate?.sidebarNewLabel() }
            default: nil
            }
            cell.configure(title: title, addAction: add)
            return cell
        case let .source(source):
            let cell = outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: self) as? SidebarCell ?? SidebarCell()
            configure(cell, source, library)
            return cell
        }
    }

    private func configure(_ cell: SidebarCell, _ source: LibrarySource, _ library: LibraryController) {
        let arranger = library.arranger
        let count: Int
        switch source {
        case .memories:
            cell.configure(title: "Memories", symbol: "sparkles", count: delegate?.memoriesToday ?? 0)
        case .memory:
            return
        case .journal:
            cell.configure(title: "Journal", symbol: "book.closed", count: library.catalog.journal.count)
        case .library:
            cell.configure(title: "Library", symbol: "photo.on.rectangle", count: library.snapshot.count)
        case .favorites:
            count = library.snapshot.items.lazy.filter(\.isFavorite).count
            cell.configure(title: "Favorites", symbol: "heart", count: count)
        case .videos:
            count = library.snapshot.items.lazy.filter(\.kind.isVideo).count
            cell.configure(title: "Videos", symbol: "video", count: count)
        case .map:
            count = library.snapshot.items.lazy.filter { $0.location != nil }.count
            cell.configure(title: "Map", symbol: "map", count: count)
        case .recentlyAdded:
            cell.configure(title: "Recently Added", symbol: "clock.arrow.circlepath", count: arranger.ids(for: .recentlyAdded, recent: library.recentlyAdded).count)
        case .allAlbums:
            cell.configure(title: "All Albums", symbol: "rectangle.stack", count: library.catalog.albums.count)
        case let .album(id):
            guard let album = library.catalog.album(id) else { return }
            let summary = arranger.summary(of: album)
            cell.configure(title: album.title, symbol: "photo", count: summary.count)
            if let cover = summary.cover { loadCover(cover, album: id, into: cell, library) }
        case let .label(id):
            guard let label = library.catalog.label(id) else { return }
            cell.configure(title: label.displayName, symbol: nil, count: arranger.ids(for: source).count, dot: Theme.color(label.color))
        case let .sharedAlbum(id):
            guard let album = delegate?.sharing.sharedWithMe(id) else { return }
            cell.configure(title: album.title, symbol: "person.2", count: arranger.ids(for: source).count)
            if let cover = album.coverID { loadCover(cover, album: id, into: cell, library) }
        }
    }

    private func loadCover(_ cover: PhotoID, album: UUID, into cell: SidebarCell, _ library: LibraryController) {
        let pixels: CGFloat = 40
        if let image = library.thumbnails.cached(cover, pixels: pixels) {
            cell.setCover(image)
            return
        }
        requests[album]?.cancel()
        cell.coverID = cover
        requests[album] = library.thumbnails.request(cover, pixels: pixels) { [weak cell] image in
            guard let cell, cell.coverID == cover, let image else { return }
            cell.setCover(image)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode, let source = node.source else { return }
        selectedSource = source
        delegate?.sidebarSelect(source)
    }

    // MARK: Dropping

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? SidebarNode else { return [] }
        if !PhotoDrag.holdsPhotos(info.draggingPasteboard) {
            // Photos and videos from another app.
            let count = FileDrop.importableCount(info)
            guard count > 0, Self.fileTarget(node) != nil else { return [] }
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            info.numberOfValidItemsForDrop = count
            return .copy
        }
        switch node.kind {
        case .heading("Albums"):
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        case let .source(source):
            switch source {
            case .album, .label, .favorites, .allAlbums:
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .copy
            default: return []
            }
        default:
            return []
        }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let ids = PhotoDrag.ids(from: info.draggingPasteboard)
        guard let node = item as? SidebarNode, let delegate else { return false }
        if ids.isEmpty {
            guard let target = Self.fileTarget(node), FileDrop.importableCount(info) > 0 else { return false }
            FileDrop.receive(info.draggingPasteboard) { [weak self] urls in self?.delegate?.sidebarDropFiles(urls, on: target) }
            return true
        }
        switch node.kind {
        case .heading: return delegate.sidebarDropOnAlbumsHeading(ids)
        case .source(.allAlbums): return delegate.sidebarDropOnAlbumsHeading(ids)
        case let .source(source): return delegate.sidebarDrop(ids, on: source)
        }
    }

    /// Where photos and videos dropped from another app on a row go; nil for rows they can't go to.
    static func fileTarget(_ node: SidebarNode) -> FileDropTarget? {
        switch node.kind {
        case .heading("Albums"): .newAlbum
        case .heading: nil
        case let .source(source):
            switch source {
            case .library, .videos, .recentlyAdded: .library
            case .favorites: .favorites
            case let .album(id): .album(id)
            case let .label(id): .label(id)
            case .allAlbums: .newAlbum
            case .memories, .memory, .journal, .map, .sharedAlbum: nil
            }
        }
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode, let source = node.source,
              let built = delegate?.sidebarMenu(for: source) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }
}

/// A sidebar row: an icon (or an album's cover, or a label's color), the name and a count.
final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
    private let icon = NSImageView()
    private let cover = NSView()
    private let countField = NSTextField(labelWithString: "")
    private var dot: LabelDot?
    var coverID: PhotoID?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        textField = title
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = Theme.accent
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 4
        cover.layer?.masksToBounds = true
        cover.layer?.contentsGravity = .resizeAspectFill
        cover.isHidden = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        countField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countField.textColor = .secondaryLabelColor
        countField.alignment = .right
        countField.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, cover, title, countField] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            cover.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            cover.centerYAnchor.constraint(equalTo: centerYAnchor),
            cover.widthAnchor.constraint(equalToConstant: 20),
            cover.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: countField.leadingAnchor, constant: -6),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, symbol: String?, count: Int, dot color: NSColor? = nil) {
        if textField?.currentEditor() == nil { textField?.stringValue = title }
        textField?.isEditable = false
        countField.stringValue = count > 0 ? NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal) : ""
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = symbol == nil
        cover.isHidden = true
        cover.layer?.contents = nil
        coverID = nil
        dot?.removeFromSuperview()
        dot = nil
        if let color {
            let dot = LabelDot(color: color, size: 12)
            addSubview(dot)
            NSLayoutConstraint.activate([dot.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
                                         dot.centerYAnchor.constraint(equalTo: centerYAnchor)])
            self.dot = dot
        }
        setAccessibilityLabel(count > 0 ? "\(title), \(count)" : title)
    }

    func setCover(_ image: CGImage) {
        cover.layer?.contents = image
        cover.isHidden = false
        icon.isHidden = true
    }
}

/// A heading in the sidebar, with a + button for Albums and Labels.
final class SidebarHeadingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeadingCell")
    private let addButton = NSButton()
    private var addAction: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        textField = title
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        addButton.isBordered = false
        addButton.bezelStyle = .regularSquare
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(add(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(addButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, addAction: (() -> Void)?) {
        textField?.stringValue = title
        self.addAction = addAction
        addButton.isHidden = addAction == nil
        addButton.setAccessibilityLabel(title == "Albums" ? "New Album" : "New Label")
    }

    @objc private func add(_ sender: Any?) { addAction?() }
}
