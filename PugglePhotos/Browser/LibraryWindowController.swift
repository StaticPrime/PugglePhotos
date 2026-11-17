import AppKit
import PugglePhotosKit
import SwiftUI

/// The library window: the sidebar on the left, photos in the middle (as a grid, a list, album covers or one photo
/// at a time) and the info panel on the right. It works out what the middle shows and handles every command.
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    let library: LibraryController
    let memories: MemoriesController
    let state: BrowserState
    let sidebar = SidebarViewController()
    let grid = PhotoGridViewController()
    let list = PhotoListViewController()
    let albums = AlbumsViewController()
    let viewer = ViewerViewController()
    private(set) lazy var book: BookViewController = {
        let book = BookViewController(library: library)
        book.onOpenPhoto = { [weak self] id in self?.openViewer(id) }
        book.onProblem = { [weak self] title, message in self?.showProblem(title, message) }
        return book
    }()
    let inspectorModel: InspectorModel
    private(set) var content = BrowserContent()
    private(set) var splitController: NSSplitViewController!
    private(set) var inspectorItem: NSSplitViewItem!
    private(set) var sidebarItem: NSSplitViewItem!
    private let container = NSViewController()
    private var shownChild: NSViewController?
    private var welcomeHost: NSHostingController<WelcomeView>?
    private var emptyHost: NSHostingController<EmptyStateView>?
    private(set) var memoriesHost: NSHostingController<MemoriesView>?
    private(set) var journalHost: NSHostingController<JournalView>?
    /// What's being written at the top of the Journal page.
    let journalComposer = JournalComposer()
    /// The journal as the headings last showed it, to tell when they need redrawing.
    private var shownJournal: [String: JournalEntry] = [:]
    /// Places visited before, for Back.
    private(set) var history: [LibrarySource] = []
    var toolbarController: ToolbarController!
    private var observers: [NSObjectProtocol] = []
    var activePopover: NSPopover?
    private var lastShowsBadges = UserDefaults.standard.bool(forKey: Preferences.showsBadgesKey)

    init(library: LibraryController, memories: MemoriesController) {
        self.library = library
        self.memories = memories
        state = BrowserState(defaults: Self.browserDefaults)
        inspectorModel = InspectorModel(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 480)
        window.title = "Library"
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.setFrameAutosaveName("LibraryWindow")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        build()
        library.reportProblem = { [weak self] title, message in self?.showProblem(title, message) }
        observers.append(NotificationCenter.default.addObserver(forName: .libraryDidChange, object: library, queue: .main) { [weak self] note in
            let change = note.userInfo?["change"] as? LibraryController.Change
            MainActor.assumeIsolated { self?.libraryChanged(change) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .memoriesDidChange, object: memories, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoriesChanged() }
        })
        if window.frame.width < 800 { window.setContentSize(NSSize(width: 1280, height: 820)) }
        sidebar.reload()
        sidebar.select(.library)
        refresh(keepPosition: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Where view settings are remembered. Debug runs on the sample library start fresh each time instead.
    static var browserDefaults: UserDefaults {
        #if DEBUG
        if DebugLaunchOptions.usesSampleLibrary { return DebugLaunchOptions.sampleDefaults }
        #endif
        return .standard
    }

    // MARK: Building the window

    private func build() {
        sidebar.defaults = Self.browserDefaults
        grid.delegate = self
        list.delegate = self
        list.onSort = { [weak self] sort, ascending in self?.setSort(sort, ascending: ascending) }
        albums.delegate = self
        viewer.delegate = self
        sidebar.delegate = self
        inspectorModel.actions = self
        grid.thumbnailSide = state.thumbnailSide

        container.view = NSView()
        splitController = NSSplitViewController()
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340
        sidebarItem.preferredThicknessFraction = 0.17
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 420
        let inspectorHost = NSHostingController(rootView: InspectorView(model: inspectorModel))
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspectorItem.minimumThickness = 250
        inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = !UserDefaults.standard.bool(forKey: "ShowsInspector")
        splitController.splitViewItems = [sidebarItem, contentItem, inspectorItem]
        splitController.splitView.autosaveName = "LibrarySplit"
        window?.contentViewController = splitController
        toolbarController = ToolbarController(window: self)
        window?.toolbar = toolbarController.toolbar
        sidebar.showsCalendar = UserDefaults.standard.bool(forKey: Preferences.showsCalendarKey)
    }

    /// Puts one view controller in the middle.
    private func show(_ child: NSViewController) {
        guard shownChild !== child else { return }
        shownChild?.view.removeFromSuperview()
        shownChild?.removeFromParent()
        container.addChild(child)
        let view = child.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        shownChild = child
    }

    // MARK: What the middle shows

    var currentAlbum: Album? { state.source.album.flatMap { library.catalog.album($0) } }

    var arrangement: Arrangement { state.arrangement(for: state.source, album: currentAlbum) }

    /// Album IDs in the order the sidebar and the album covers use.
    var albumOrder: [UUID] { library.sortedAlbumIDs(sort: state.albumSort, ascending: state.albumSortAscending) }

    /// The memory whose photos are showing, if any.
    var currentMemory: Memory? {
        if case let .memory(id) = state.source { return memories.memory(id) }
        return nil
    }

    /// The photos the current place shows, before sorting and grouping.
    private func sourceIDs() -> [PhotoID] {
        let arranger = library.arranger
        var ids = arranger.ids(for: state.source, recent: library.recentlyAdded, memory: currentMemory?.items ?? [])
        let search = PhotoSearch(state.searchText, formatting: library.formatting)
        if !search.isEmpty { ids = search.filter(ids, using: arranger) }
        return ids
    }

    func makeContent() -> BrowserContent {
        let arranger = library.arranger
        let arrangement = arrangement
        let ids = arranger.sorted(sourceIDs(), by: arrangement.sort, ascending: arrangement.ascending)
        var content = BrowserContent()
        content.sections = arranger.sections(ids, arrangement: arrangement, albumOrder: albumOrder)
        content.showsHeaders = arrangement.grouping != .none
        let today = CivilDay(Date(), in: library.formatting.timeZone)
        let journal = library.catalog.journal
        shownJournal = journal
        for section in content.sections {
            content.titles.append(arranger.title(of: section.key, formatting: library.formatting, today: today))
            let counts = library.snapshot.counts(of: section.items)
            content.subtitles.append(library.formatting.count(photos: counts.photos, videos: counts.videos))
            switch section.key {
            case let .day(day): content.drops.append(.day(day))
            case let .album(id): content.drops.append(.album(id))
            case let .label(id): content.drops.append(.label(id))
            default: content.drops.append(nil)
            }
            if case let .day(day) = section.key, let entry = journal[day.description] {
                content.journal.append(Self.journalLine(entry))
            } else {
                content.journal.append("")
            }
        }
        if let album = currentAlbum {
            content.album = album
            let summary = arranger.summary(of: album)
            content.albumSubtitle = [library.formatting.dateRange(from: summary.firstDate, to: summary.lastDate),
                                     library.formatting.count(photos: summary.photos, videos: summary.videos)]
                .compactMap { $0 }.joined(separator: " · ")
        }
        content.dropsBetween = arrangement.isDateOrdered || (currentAlbum != nil && arrangement.sort == .custom)
        return content
    }

    /// A journal entry as a heading shows it: the mood, then the words on one line.
    static func journalLine(_ entry: JournalEntry) -> String {
        let words = entry.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return [entry.mood, words].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    /// Works out the middle again and shows it.
    func refresh(keepPosition: Bool) {
        let previousSource = shownSource
        shownSource = state.source
        toolbarController?.update()
        updateTitle()
        if library.access != .authorized {
            showWelcome(library.access == .notDetermined ? .ask : .denied)
            return
        }
        if !library.hasLoaded {
            showWelcome(.loading)
            return
        }
        if let viewerID = state.viewerID, library.snapshot.contains(viewerID) {
            show(viewer)
            viewer.showsFilmstrip = state.showsFilmstrip
            viewer.setSequence(viewerSequence)
            viewer.show(viewerID)
            return
        }
        state.viewerID = nil
        if state.source == .memories {
            showMemories()
            setSelection([])
            return
        }
        if state.source == .journal {
            showJournal()
            setSelection([])
            return
        }
        if state.source == .allAlbums {
            albums.show(library.arranger.albumSummaries(sort: state.albumSort, ascending: state.albumSortAscending),
                        thumbnailSide: state.thumbnailSide)
            show(albums)
            setSelection([])
            return
        }
        content = makeContent()
        let selection = state.selection.filter { library.snapshot.contains($0) }
        if state.viewMode == .book, let album = currentAlbum {
            show(book)
            book.show(album: album.id)
            setSelection([], notify: false)
            return
        }
        if content.isEmpty, content.album == nil {
            showEmptyState()
        } else if state.viewMode == .list {
            show(list)
            list.show(content, selecting: selection, sort: arrangement.sort, ascending: arrangement.ascending)
        } else {
            show(grid)
            let samePlace = keepPosition && previousSource == state.source
            grid.show(content, selecting: selection, keepPosition: samePlace)
            // The timeline opens on the newest photos, at the bottom, once they've been laid out.
            if opensAtEnd, selection.isEmpty, arrangement.sort == .dateTaken, arrangement.ascending, state.source == .library,
               state.searchText.isEmpty {
                opensAtEnd = false
                DispatchQueue.main.async { [weak self] in self?.grid.scrollToEnd() }
            }
        }
        setSelection(selection, notify: false)
    }

    private var shownSource: LibrarySource?

    /// Whether an album is open as a photo book.
    var isShowingBook: Bool { shownChild === book && state.viewerID == nil }
    /// Set when the library is about to be shown afresh, so it opens on the newest photos.
    private var opensAtEnd = true

    private func showWelcome(_ welcome: WelcomeView.State) {
        let view = WelcomeView(state: welcome, onAllow: { [weak self] in self?.library.requestAccess() },
                               onOpenSettings: {
                                   if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                                       NSWorkspace.shared.open(url)
                                   }
                               })
        if let welcomeHost { welcomeHost.rootView = view } else { welcomeHost = NSHostingController(rootView: view) }
        show(welcomeHost!)
    }

    private func showMemories() {
        if memoriesHost == nil {
            memoriesHost = NSHostingController(rootView: MemoriesView(memories: memories, actions: { [weak self] in self }))
        }
        show(memoriesHost!)
    }

    private func showJournal() {
        if journalHost == nil {
            journalHost = NSHostingController(rootView: JournalView(library: library, composer: journalComposer, actions: { [weak self] in self }))
        }
        show(journalHost!)
    }

    private func showEmptyState() {
        let view: EmptyStateView
        if !state.searchText.isEmpty {
            view = EmptyStateView(symbol: "magnifyingglass", title: "No Results",
                                  message: "Nothing here matches “\(state.searchText)”. Search looks at captions, notes, labels, albums, file names, kinds, months and years.")
        } else {
            view = switch state.source {
            case .favorites: EmptyStateView(symbol: "heart", title: "No Favorites Yet",
                                            message: "Press period (.) or click the heart in the toolbar to make a photo a favorite. Favorites show here and in your Photos library.")
            case .videos: EmptyStateView(symbol: "video", title: "No Videos", message: "Videos in your Photos library show here.")
            case .recentlyAdded: EmptyStateView(symbol: "clock", title: "Nothing Added Lately",
                                                message: "Photos added to your Photos library in the last 30 days show here.")
            case .label: EmptyStateView(symbol: "tag", title: "No Photos with This Label",
                                        message: "Drag photos onto the label in the sidebar, or press ⌃ and the label’s number.")
            default: EmptyStateView(symbol: "photo.on.rectangle.angled", title: "No Photos",
                                    message: "Photos and videos in your Photos library show here.")
            }
        }
        if let emptyHost { emptyHost.rootView = view } else { emptyHost = NSHostingController(rootView: view) }
        show(emptyHost!)
    }

    func updateTitle() {
        guard let window else { return }
        let formatting = library.formatting
        switch state.source {
        case .memories: window.title = "Memories"
        case .memory: window.title = currentMemory?.title ?? "Memory"
        case .journal: window.title = "Journal"
        case .library: window.title = "Library"
        case .favorites: window.title = "Favorites"
        case .videos: window.title = "Videos"
        case .recentlyAdded: window.title = "Recently Added"
        case .allAlbums: window.title = "Albums"
        case let .album(id): window.title = library.catalog.album(id)?.title ?? "Album"
        case let .label(id): window.title = library.catalog.label(id)?.displayName ?? "Label"
        }
        if state.source == .allAlbums {
            window.subtitle = library.catalog.albums.count == 1 ? "1 album" : "\(formatting.number(library.catalog.albums.count)) albums"
            return
        }
        if state.source == .memories {
            window.subtitle = formatting.weekdayAndDay(memories.today)
            return
        }
        if state.source == .journal {
            let entries = library.catalog.journal.count
            window.subtitle = entries == 1 ? "1 entry" : "\(formatting.number(entries)) entries"
            return
        }
        guard library.hasLoaded else {
            window.subtitle = ""
            return
        }
        let ids = Set(content.allIDs)
        let counts = library.snapshot.counts(of: ids)
        var subtitle = formatting.count(photos: counts.photos, videos: counts.videos)
        if state.selection.count > 1 { subtitle += " · \(formatting.number(state.selection.count)) selected" }
        window.subtitle = subtitle
    }

    // MARK: Changes

    private func libraryChanged(_ change: LibraryController.Change?) {
        sidebar.reload()
        if shownChild === book {
            book.libraryChanged()
            updateTitle()
            return
        }
        switch change {
        case .catalog?:
            // Captions and labels change badges; albums and labels can change what's shown.
            let dependsOnCatalog = state.source.album != nil || state.source.label != nil || !state.searchText.isEmpty
                || arrangement.grouping == .album || arrangement.grouping == .label || arrangement.sort == .title
                || (arrangement.grouping == .day && library.catalog.journal != shownJournal)
            if state.source == .journal {
                updateTitle()
            } else if dependsOnCatalog || state.source == .allAlbums || shownChild === emptyHost {
                refresh(keepPosition: true)
            } else {
                grid.refreshVisible()
                list.refreshVisible()
                updateTitle()
            }
            if state.viewerID != nil { viewer.updateCaption() }
        default:
            refresh(keepPosition: true)
        }
        inspectorModel.ids = state.selection.filter { library.snapshot.contains($0) }
    }

    private func memoriesChanged() {
        sidebar.refreshRows()
        if case .memory = state.source { refresh(keepPosition: true) }
        if state.source == .memories { updateTitle() }
    }

    private func preferencesChanged() {
        let showsCalendar = UserDefaults.standard.bool(forKey: Preferences.showsCalendarKey)
        if sidebar.showsCalendar != showsCalendar { sidebar.showsCalendar = showsCalendar }
        let showsBadges = UserDefaults.standard.bool(forKey: Preferences.showsBadgesKey)
        if showsBadges != lastShowsBadges {
            lastShowsBadges = showsBadges
            grid.refreshVisible()
        }
    }


    // MARK: Selection and navigation

    func setSelection(_ ids: [PhotoID], notify: Bool = true) {
        state.selection = ids
        inspectorModel.ids = ids
        updateTitle()
        toolbarController?.update()
    }

    /// Goes to a place in the sidebar.
    func go(to source: LibrarySource, remember: Bool = true) {
        closeViewer(refreshing: false)
        if remember, source != state.source { history.append(state.source) }
        if history.count > 50 { history.removeFirst() }
        state.source = source
        state.selection = []
        opensAtEnd = true
        if !state.searchText.isEmpty {
            state.searchText = ""
            toolbarController.clearSearch()
        }
        sidebar.select(source)
        refresh(keepPosition: false)
        setSelection([])
    }

    func goBack() {
        if state.viewerID != nil {
            closeViewer()
            return
        }
        guard let previous = history.popLast() else { return }
        go(to: previous, remember: false)
    }

    var canGoBack: Bool { state.viewerID != nil || !history.isEmpty }

    func openViewer(_ id: PhotoID) {
        state.viewerID = id
        if !state.selection.contains(id) { setSelection([id]) }
        refresh(keepPosition: true)
        window?.makeFirstResponder(viewer.view)
    }

    func closeViewer(refreshing: Bool = true) {
        guard let id = state.viewerID else { return }
        state.viewerID = nil
        viewer.stop()
        guard refreshing else { return }
        refresh(keepPosition: true)
        setSelection([id])
        if state.viewMode == .gallery {
            grid.select([id])
            grid.scroll(to: id, animated: false)
            window?.makeFirstResponder(grid.collectionView)
        } else {
            list.select([id])
            window?.makeFirstResponder(list.tableView)
        }
    }

    /// Selects photos in whatever's showing and scrolls to the first.
    func reveal(_ ids: [PhotoID]) {
        let present = ids.filter { content.allIDs.contains($0) }
        guard !present.isEmpty else { return }
        if state.viewMode == .gallery, shownChild === grid {
            grid.select(present)
            if let first = present.first { grid.scroll(to: first) }
        } else if shownChild === list {
            list.select(present)
        }
    }

    // MARK: Arranging

    func setGrouping(_ grouping: Grouping) {
        var arrangement = arrangement
        arrangement.grouping = grouping
        state.setArrangement(arrangement, for: state.source)
        refresh(keepPosition: false)
    }

    func setSort(_ sort: SortKey, ascending: Bool? = nil) {
        if let album = currentAlbum {
            let order: AlbumOrder = sort == .custom ? .custom : ((ascending ?? arrangement.ascending) ? .oldestFirst : .newestFirst)
            library.edit("Sort Album") { $0.setAlbumOrder(album.id, to: order) }
            return
        }
        var arrangement = arrangement
        arrangement.sort = sort
        if let ascending { arrangement.ascending = ascending }
        state.setArrangement(arrangement, for: state.source)
        refresh(keepPosition: false)
    }

    func setAscending(_ ascending: Bool) {
        if let album = currentAlbum {
            guard album.order != .custom else { return }
            library.edit("Sort Album") { $0.setAlbumOrder(album.id, to: ascending ? .oldestFirst : .newestFirst) }
            return
        }
        var arrangement = arrangement
        arrangement.ascending = ascending
        state.setArrangement(arrangement, for: state.source)
        refresh(keepPosition: false)
    }

    func setViewMode(_ mode: ViewMode) {
        if mode == .book, currentAlbum == nil {
            NSSound.beep()
            return
        }
        if !state.source.showsPhotos { go(to: .library) }
        closeViewer(refreshing: false)
        state.viewMode = mode
        refresh(keepPosition: false)
    }

    func setThumbnailSide(_ side: CGFloat) {
        state.thumbnailSide = min(max(side, Theme.minimumThumbnail), Theme.maximumThumbnail)
        grid.thumbnailSide = state.thumbnailSide
        if state.source == .allAlbums {
            albums.show(library.arranger.albumSummaries(sort: state.albumSort, ascending: state.albumSortAscending),
                        thumbnailSide: state.thumbnailSide)
        }
        toolbarController.update()
    }

    func setAlbumSort(_ sort: AlbumSort, ascending: Bool? = nil) {
        state.albumSort = sort
        if let ascending { state.albumSortAscending = ascending }
        sidebar.reload()
        refresh(keepPosition: true)
    }

    func search(_ text: String) {
        guard text != state.searchText else { return }
        state.searchText = text
        if !state.source.showsPhotos { state.source = .library; sidebar.select(.library) }
        closeViewer(refreshing: false)
        refresh(keepPosition: false)
    }

    // MARK: Window

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { library.undoManager }

    func windowWillClose(_ notification: Notification) {
        viewer.stop()
        rememberLayout()
        library.saveNow()
    }

    /// Remembers whether the info panel is open, for next time.
    func rememberLayout() {
        UserDefaults.standard.set(!inspectorItem.isCollapsed, forKey: "ShowsInspector")
    }

    func showProblem(_ title: String, _ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Shows SwiftUI content as a sheet; the content gets a closure that ends it.
    func presentSheet<Content: View>(_ make: (@escaping () -> Void) -> Content) {
        guard let window, window.attachedSheet == nil else { return }
        var sheet: NSWindow?
        let dismiss = { [weak window] in
            if let sheet { window?.endSheet(sheet) }
        }
        let host = NSHostingController(rootView: make(dismiss))
        sheet = NSWindow(contentViewController: host)
        sheet?.styleMask = [.titled]
        window.beginSheet(sheet!)
    }

    /// Shows SwiftUI content in a popover next to a rectangle of a view. `onClose` runs when it closes, whether by
    /// its own buttons or a click elsewhere.
    func presentPopover<Content: View>(at rect: NSRect, of view: NSView, edge: NSRectEdge = .maxY, onClose: (() -> Void)? = nil,
                                       _ make: (@escaping () -> Void) -> Content) {
        activePopover?.close()
        let popover = ClosingPopover()
        popover.behavior = .transient
        popover.onClose = onClose
        let close: () -> Void = { [weak popover] in popover?.close() }
        popover.contentViewController = NSHostingController(rootView: make(close))
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
        activePopover = popover
    }
}

/// A popover that runs a closure once when it closes, however it closes.
final class ClosingPopover: NSPopover, NSPopoverDelegate {
    var onClose: (() -> Void)?

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func popoverDidClose(_ notification: Notification) {
        let action = onClose
        onClose = nil
        action?()
    }
}
