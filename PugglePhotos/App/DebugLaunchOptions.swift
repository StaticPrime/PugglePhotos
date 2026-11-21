#if DEBUG
import AppKit
import PugglePhotosKit

/// Launch arguments for checking the app without clicking through it, all starting with `PH`:
/// `-PHSampleLibrary YES` uses the made-up sample library instead of the Photos library, and
/// `-PHSnapshot <file name>` writes a PNG of the window to the app's temporary folder and quits.
/// The rest set up what the snapshot shows (see `runIfRequested`).
enum DebugLaunchOptions {
    static var defaults: UserDefaults { .standard }

    /// Screenshots, the self-test and the benchmark always use the sample library, so automated runs never touch
    /// the real Photos library or catalog.
    static var usesSampleLibrary: Bool {
        defaults.bool(forKey: "PHSampleLibrary") || defaults.bool(forKey: "PHSelfTest") || defaults.bool(forKey: "PHBenchmark")
            || defaults.string(forKey: "PHSnapshot") != nil
    }

    /// The day the sample library treats as today: `-PHToday 2026-11-17`, else the real today.
    static var sampleToday: Date {
        if let text = defaults.string(forKey: "PHToday") {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) {
                return date
            }
        }
        return Date()
    }

    /// The sample library's clock: its today, at the real time of day. Memories and their notifications go by it, so
    /// they find the days the sample library made up whatever day it runs on.
    static var sampleClock: () -> Date {
        let calendar = Calendar.current
        let shift = calendar.startOfDay(for: sampleToday).timeIntervalSince(calendar.startOfDay(for: Date()))
        return { Date().addingTimeInterval(shift) }
    }

    static func makeSampleSource() -> SamplePhotoSource {
        let access: LibraryAccess = switch defaults.string(forKey: "PHAccess") {
        case "ask": .notDetermined
        case "denied": .denied
        default: .authorized
        }
        let count = defaults.integer(forKey: "PHSampleCount") + (defaults.bool(forKey: "PHBenchmark") ? 60_000 : 0)
        return SamplePhotoSource(today: sampleToday, count: count, access: access)
    }

    /// View settings for sample-library runs, emptied at launch so every run starts the same way. `-PHSavedViewMode list`
    /// (or `book`) starts as if the last run had been left showing that.
    static let sampleDefaults: UserDefaults = {
        let name = "com.pugglesoft.PugglePhotos.sample"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        if let mode = UserDefaults.standard.string(forKey: "PHSavedViewMode") { defaults.set(mode, forKey: "ViewMode") }
        return defaults
    }()

    /// A fresh folder for the sample library's shared albums.
    static let sampleSharedStore = SharedAlbumsStore(folder: FileManager.default.temporaryDirectory
        .appendingPathComponent("PugglePhotos Sample Shared Albums \(UUID().uuidString)", isDirectory: true))

    /// A fresh folder for the sample catalog, so the real one is never touched.
    static let sampleStore: CatalogStore? = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PugglePhotos Sample Catalog \(UUID().uuidString)", isDirectory: true)
        return CatalogStore(folder: folder)
    }()

    static func runIfRequested(_ app: AppDelegate) {
        runBenchmark(app)
        guard let name = defaults.string(forKey: "PHSnapshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let controller = app.windowController, let window = controller.window else { return }
            let width = defaults.double(forKey: "PHWindowWidth"), height = defaults.double(forKey: "PHWindowHeight")
            if width > 0 || height > 0 {
                window.setContentSize(NSSize(width: width > 0 ? width : window.contentLayoutRect.width,
                                             height: height > 0 ? height : window.frame.height))
            }
            if let inspector = defaults.object(forKey: "PHInspector") as? String {
                controller.inspectorItem.isCollapsed = !(inspector == "YES" || inspector == "1")
            }
            setUpOnceShared(controller, app: app, tries: 0)
            if defaults.bool(forKey: "PHDebugLayout") { print("PHDebug: window=\(window.windowNumber)"); fflush(stdout) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (defaults.double(forKey: "PHSnapshotDelay") > 0 ? defaults.double(forKey: "PHSnapshotDelay") : 2.6)) {
            snapshot(name, app: app)
        }
    }

    /// `-PHSource memories|journal|library|favorites|videos|recent|albums|album:N|label:N` picks the place;
    /// `-PHViewMode list`, `-PHGrouping month`, `-PHSort title`, `-PHDescending YES`, `-PHZoom 220` and
    /// `-PHSearch text` set how it shows; `-PHSelect 3` (or `3,4,5`) selects photos by position;
    /// `-PHViewer YES` opens the first selected; `-PHCalendar 2019-07` turns the calendar;
    /// `-PHRedate day|between` shows the question asked when photos are dropped; `-PHOpenSheet
    /// changeDate|shortcuts|newLabel|journal` opens a sheet; `-PHShowAbout YES` and `-PHSettings YES` open those windows.
    /// Albums shared with you come a moment after launch: a place among them waits for them.
    private static func setUpOnceShared(_ controller: LibraryWindowController, app: AppDelegate, tries: Int) {
        if defaults.string(forKey: "PHSource")?.hasPrefix("shared") == true, app.sharing.sharedWithMe.isEmpty, tries < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { setUpOnceShared(controller, app: app, tries: tries + 1) }
            return
        }
        setUp(controller, app: app)
    }

    private static func setUp(_ controller: LibraryWindowController, app: AppDelegate) {
        let library = app.library!
        if let source = defaults.string(forKey: "PHSource") {
            let parts = source.split(separator: ":")
            let index = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            switch parts.first {
            case "memories": controller.go(to: .memories)
            case "journal": controller.go(to: .journal)
            case "favorites": controller.go(to: .favorites)
            case "videos": controller.go(to: .videos)
            case "map": controller.go(to: .map)
            case "recent": controller.go(to: .recentlyAdded)
            case "albums": controller.go(to: .allAlbums)
            case "album":
                let albums = library.catalog.albums
                if albums.indices.contains(index - 1) { controller.go(to: .album(albums[index - 1].id)) }
            case "label":
                let labels = library.catalog.labels
                if labels.indices.contains(index - 1) { controller.go(to: .label(labels[index - 1].id)) }
            case "shared":
                let shared = app.sharing.sharedWithMe.sorted { $0.title < $1.title }
                if shared.indices.contains(index - 1) { controller.go(to: .sharedAlbum(shared[index - 1].id)) }
            default: break
            }
        }
        // `-PHShareAlbum YES` shares the album showing (with the stand-in for iCloud), `-PHShareInvite name@example.com`
        // inviting someone to it; `-PHShareSheet YES` opens the sharing sheet for it, or for a new shared album.
        if defaults.bool(forKey: "PHShareAlbum"), let album = controller.currentAlbum?.id {
            app.sharing.share(album, access: .invited) { _ in
                if let address = defaults.string(forKey: "PHShareInvite") { app.sharing.invite(address, to: album) { _ in } }
                if defaults.bool(forKey: "PHShareSheet") { controller.presentShareSheet(album: album) }
            }
        } else if defaults.bool(forKey: "PHShareSheet") {
            controller.presentShareSheet(album: controller.currentAlbum?.id)
        }
        if let mode = defaults.string(forKey: "PHViewMode").flatMap(ViewMode.init(rawValue:)) { controller.setViewMode(mode) }
        if let grouping = defaults.string(forKey: "PHGrouping").flatMap(Grouping.init(rawValue:)) { controller.setGrouping(grouping) }
        if let sort = defaults.string(forKey: "PHSort").flatMap(SortKey.init(rawValue:)) { controller.setSort(sort) }
        if defaults.object(forKey: "PHDescending") != nil { controller.setAscending(!defaults.bool(forKey: "PHDescending")) }
        // `-PHViewMode book` opens an album as a book: `-PHBookState 2` turns to the second spread, `-PHBookPaper black`,
        // `-PHBookFrame print`, `-PHBookTilt playful` and `-PHBookLayout one` restyle it, `-PHBookSelect YES` picks its first
        // photo, and `-PHBookTurn 0.4` holds a page partway through turning. `-PHBookNotes sticky` (or `onPhoto`,
        // `underPhoto`, `hidden`) shows the notes that way, `-PHBookHandwriting "Marker Felt"` writes in that hand,
        // `-PHBookTurnOver YES` turns the first photo on the spread over, and `-PHBookSticky YES` picks a sticky note.
        if controller.isShowingBook {
            let book = controller.book
            if let value = defaults.string(forKey: "PHBookPaper"), let paper = BookPaper(rawValue: value) { book.change("Paper") { $0.paper = paper } }
            if let value = defaults.string(forKey: "PHBookFrame"), let frame = BookFrame(rawValue: value) { book.change("Frames") { $0.frame = frame } }
            if let value = defaults.string(forKey: "PHBookTilt"), let tilt = BookTilt(rawValue: value) { book.change("Tilt") { $0.tilt = tilt } }
            if let value = defaults.string(forKey: "PHBookLayout"), let perPage = BookPerPage(rawValue: value) { book.change("Layout") { $0.perPage = perPage } }
            if let value = defaults.string(forKey: "PHBookNotes"), let notes = BookNoteStyle(rawValue: value) { book.change("Notes") { $0.notes = notes } }
            if let value = defaults.string(forKey: "PHBookHandwriting") { book.change("Handwriting") { $0.handwriting = value } }
            if let value = defaults.string(forKey: "PHBookBinding"), let binding = BookBinding(rawValue: value) { book.change("Binding") { $0.binding = binding } }
            if let value = defaults.string(forKey: "PHBookRings"), let rings = BookRingFinish(rawValue: value) { book.change("Rings") { $0.rings = rings } }
            if let value = defaults.string(forKey: "PHBookCover"), let cover = BookCover(rawValue: value) { book.change("Cover") { $0.cover = cover } }
            let place = defaults.integer(forKey: "PHBookState")
            if place > 0 { book.bookView.go(to: place, animated: false) }
            if defaults.bool(forKey: "PHBookSelect") {
                let pages = book.layout.state(book.bookView.state)
                let first = [pages.left, pages.right].compactMap { $0 }.flatMap { book.layout.pages[$0].placements }.first { _ in true }
                if let first, book.layout.pages[book.layout.find(first.id)?.page ?? 0].kind == .photos { book.bookView.select(first.id) }
            }
            // `-PHShowHandleSpots YES` paints where the handles of what's picked take hold.
            if defaults.bool(forKey: "PHShowHandleSpots") { book.bookView.showHandleSpotsForTesting() }
            let showing = book.layout.state(book.bookView.state)
            let photos = [showing.left, showing.right].compactMap { $0 }.flatMap { book.layout.pages[$0].kind == .photos ? book.layout.pages[$0].placements : [] }
            if defaults.bool(forKey: "PHBookTurnOver"), let first = photos.first {
                book.bookView.select(first.id)
                book.bookView.setTurnedOver(first.id)
            }
            if defaults.bool(forKey: "PHBookSticky"), let noted = photos.first(where: \.hasSticky) { book.bookView.pick(.sticky(noted.id)) }
            // `-PHBookWriting YES` writes a few words on each open page, and `-PHBookWriteMode YES` turns writing on.
            if defaults.bool(forKey: "PHBookWriting") {
                let samples = ["Summer at the shore, all of us together.", "Best day ever!", "We’ll come back next year. Promise."]
                for (number, page) in [showing.left, showing.right].compactMap({ $0 }).enumerated() {
                    if var writing = book.bookNewWriting(at: CGPoint(x: 70, y: number == 0 ? 720 : 60), onPage: page) {
                        writing.text = samples[number % samples.count]
                        writing.angle = number == 0 ? -4 : 3
                        writing.size = number == 0 ? 30 : 26
                        book.bookCommitWriting(writing, actionName: "Write on Page")
                    }
                }
            }
            if defaults.bool(forKey: "PHBookWriteMode") { book.setWriting(true) }
            // `-PHBookSaveEPUB name.epub` saves the book as an EPUB in the app's temporary folder.
            if let name = defaults.string(forKey: "PHBookSaveEPUB") {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                book.saveEPUB(to: url) { error in
                    print("PHBookSaveEPUB: \(error.map { "failed: \($0)" } ?? url.path)")
                    fflush(stdout)
                }
            }
            // `-PHBookCarry YES` picks up the right page's first photo and holds it partway across the spread.
            if defaults.bool(forKey: "PHBookCarry"), let right = showing.right, let first = book.layout.pages[right].placements.first {
                // Once the book has been laid out at the window's size.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let view = book.bookView
                    let start = view.viewPoint(first.center, onLeft: false)
                    SelfTest.bookMouse(.leftMouseDown, at: start, in: view)
                    SelfTest.bookMouse(.leftMouseDragged, at: CGPoint(x: start.x - 10, y: start.y), in: view)
                    SelfTest.bookMouse(.leftMouseDragged, at: CGPoint(x: start.x - view.pageSize.width * 0.55, y: start.y + 40), in: view)
                }
            }
            let turn = defaults.double(forKey: "PHBookTurn")
            if turn > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { book.bookView.holdTurn(at: turn) } }
        }
        let zoom = defaults.double(forKey: "PHZoom")
        if zoom > 0 { controller.setThumbnailSide(zoom) }
        if let text = defaults.string(forKey: "PHSearch") {
            controller.toolbarController.searchItem?.searchField.stringValue = text
            controller.search(text)
        }
        if let text = defaults.string(forKey: "PHCalendar") {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            if parts.count >= 2 { controller.sidebar.calendar.show(year: parts[0], month: parts[1]) }
        }
        if let text = defaults.string(forKey: "PHSelect") {
            let all = controller.content.allIDs
            let ids = text.split(separator: ",").compactMap { Int($0) }.filter { all.indices.contains($0 - 1) }.map { all[$0 - 1] }
            controller.setSelection(ids)
            controller.reveal(ids)
            if defaults.bool(forKey: "PHViewer"), let first = ids.first { controller.openViewer(first) }
            // `-PHGetInfo YES` opens an Info window on the first selected photo, kept showing while the app's behind.
            if defaults.bool(forKey: "PHGetInfo"), let first = ids.first {
                InfoWindowController.keepsShowingBehind = true
                controller.showInfo(for: [first])
            }
            // `-PHTurnOver YES` turns the first selected photo over in the grid; `-PHWriteNote YES` writes on its back.
            if defaults.bool(forKey: "PHTurnOver"), let first = ids.first {
                DispatchQueue.main.async {
                    controller.grid.turnOver(first, animated: false)
                    if defaults.bool(forKey: "PHWriteNote") { controller.phWriteNote(nil) }
                }
            }
        }
        // `-PHDropHighlight YES` lights up the middle as files dragged in from another app over it do.
        if defaults.bool(forKey: "PHDropHighlight"), let target = controller.fileDropTarget(at: .zero) {
            controller.dropZone.showHighlight(controller.dropTitle(target))
        }
        switch defaults.string(forKey: "PHRedate") {
        case "day":
            let day = CivilDay(year: 2019, month: 7, day: 4)
            if let rect = controller.sidebar.calendar.rect(for: day) ?? Optional(NSRect(x: 40, y: 80, width: 20, height: 20)) {
                controller.sidebar.calendar.show(day)
                controller.move(controller.state.selection, to: day, anchor: controller.sidebar.calendar.rect(for: day) ?? rect,
                                of: controller.sidebar.calendar)
            }
        case "between":
            if let first = controller.state.selection.first, let item = library.snapshot.item(first) {
                let changes = Redate.place([(id: item.id, date: item.date)], after: item.date.addingTimeInterval(-3600), before: nil)
                controller.confirm(changes, .between(library.formatting.dateAndTime(changes[0].to)), actionName: "Move Photo",
                                   anchor: NSRect(x: 200, y: 200, width: 4, height: 100), of: controller.grid.collectionView)
            }
        default: break
        }
        switch defaults.string(forKey: "PHOpenSheet") {
        case "changeDate": controller.showChangeDate(for: controller.state.selection)
        case "shortcuts": controller.phShowShortcuts(nil)
        case "newLabel": controller.newLabel(for: [])
        case "journal": controller.phWriteJournal(nil)
        default: break
        }
        // `-PHJournalDay 2026-02-08` opens the journal popover from that day's heading in the library.
        if let text = defaults.string(forKey: "PHJournalDay"), let day = CivilDay(text) {
            controller.calendarSelect(day)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let section = controller.content.sections.firstIndex(where: { $0.key == .day(day) }),
                   let header = controller.grid.collectionView.supplementaryView(forElementKind: PhotoGridLayout.headerKind,
                                                                                 at: IndexPath(item: 0, section: section)) as? SectionHeaderView {
                    header.writeButton.performClick(nil)
                }
            }
        }
        if defaults.bool(forKey: "PHShowAbout") { app.showAboutWindow(nil) }
        if defaults.bool(forKey: "PHSettings") { app.showSettings(nil) }
        // `-PHSlideshow today|album:2|highlight:1|year:1` plays a slideshow; `-PHSlideshowAt 3` jumps to its fourth
        // slide and `-PHSlideshowFreeze 0.5` stops all motion halfway through it.
        if let which = defaults.string(forKey: "PHSlideshow") {
            let memories = app.memories!
            let parts = which.split(separator: ":")
            let index = parts.count > 1 ? (Int(parts[1]) ?? 1) - 1 : 0
            let memory: Memory? = switch parts.first {
            case "album": library.catalog.albums.indices.contains(index) ? memories.finder.album(library.catalog.albums[index].id) : nil
            case "highlight": memories.page.highlights.indices.contains(index) ? memories.page.highlights[index] : nil
            case "year": memories.page.years.indices.contains(index) ? memories.page.years[index] : nil
            default: memories.page.onThisDay.indices.contains(index) ? memories.page.onThisDay[index] : nil
            }
            if let memory {
                controller.play(memory)
                if let show = SlideshowController.current {
                    let freeze = defaults.double(forKey: "PHSlideshowFreeze")
                    if freeze > 0 { show.frozenProgress = freeze }
                    for _ in 0..<defaults.integer(forKey: "PHSlideshowAt") { show.next() }
                    if defaults.bool(forKey: "PHSlideshowPaused") { show.togglePause() }
                }
            } else {
                print("PHSlideshow: no such memory")
            }
        }
        // `-PHNotificationClick YES`: as if today's memory notification were clicked.
        if defaults.bool(forKey: "PHNotificationClick"), let memory = app.memories.page.onThisDay.last {
            app.memories.notifications.onOpen?(memory.id)
        }
    }

    private static func snapshot(_ name: String, app: AppDelegate) {
        guard let controller = app.windowController, let main = controller.window else {
            print("PHSnapshot: no window")
            exit(1)
        }
        let about = NSApp.windows.first { $0.windowController is AboutWindowController && $0.isVisible }
        let settings = NSApp.windows.first { $0.windowController is SettingsWindowController && $0.isVisible }
        let slideshow = SlideshowController.current.map(\.window)
        let info = NSApp.windows.first { $0.windowController is InfoWindowController && $0.isVisible }
        if defaults.bool(forKey: "PHDebugLayout"), let show = SlideshowController.current { print("PHDebug:\n\(show.describeSlide())") }
        let window = slideshow ?? about ?? settings ?? info ?? main.attachedSheet ?? main
        guard let view = window.contentView?.superview ?? window.contentView else { exit(1) }
        // The window server's picture of the window shows vibrant sidebars and every SwiftUI view as they really
        // look; drawing the views into a bitmap misses those, so it's only the fallback.
        if let windowImage = windowServerImage(window) {
            save(windowImage.representation(using: .png, properties: [:]), as: name)
        }
        var image = capture(view)
        // A popover lives in its own window: draw it over the main window where it appears.
        if window === main, let popover = controller.activePopover, popover.isShown,
           let popoverWindow = popover.contentViewController?.view.window, let popoverView = popoverWindow.contentView?.superview,
           let base = image, let overlay = capture(popoverView) {
            let origin = NSPoint(x: popoverWindow.frame.minX - main.frame.minX, y: popoverWindow.frame.minY - main.frame.minY)
            image = compose(base, overlay, at: origin, scale: main.backingScaleFactor)
        }
        guard let image else { exit(1) }
        if defaults.bool(forKey: "PHDebugLayout") {
            let outline = controller.sidebar.outlineView!
            print("PHDebug: outline rows=\(outline.numberOfRows) frame=\(outline.frame) scroll=\(outline.enclosingScrollView?.frame ?? .zero) sidebar=\(controller.sidebar.view.frame)")
            let inspector = controller.inspectorItem.viewController.view
            print("PHDebug: inspector frame=\(inspector.frame) collapsed=\(controller.inspectorItem.isCollapsed) subviews=\(inspector.subviews.count)")
        }
        save(image.representation(using: .png, properties: [:]), as: name)
    }

    /// Writes a snapshot to the app's temporary folder, says where, and quits. With `-PHSnapshotPrint YES` it's
    /// printed too, in base64 after "PHSnapshotData: ", for when the app's own folder can't be read from outside.
    private static func save(_ png: Data?, as name: String) -> Never {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? png?.write(to: url)
        print("PHSnapshot: \(url.path)")
        if defaults.bool(forKey: "PHSnapshotPrint"), let png { print("PHSnapshotData: " + png.base64EncodedString()) }
        fflush(stdout)
        exit(0)
    }

    /// The window as the window server draws it, popovers and sheets included, through
    /// `CGWindowListCreateImage` (looked up at run time: it's deprecated, but a debug build may still use it).
    private static func windowServerImage(_ window: NSWindow) -> NSBitmapImageRep? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // Every window at or below this one, cropped to its frame, so sheets and popovers on top are included.
        var ids: [CGWindowID] = [CGWindowID(window.windowNumber)]
        ids += NSApp.windows.filter { $0.isVisible && $0 !== window && $0.frame.intersects(window.frame) && $0.level.rawValue >= window.level.rawValue }
            .map { CGWindowID($0.windowNumber) }
        let screenHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = window.frame
        let bounds = CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
        guard let image = create(bounds, 1 << 0 /* on screen only */, 0, 1 << 3 /* best resolution */)?.takeRetainedValue() else { return nil }
        _ = ids
        return NSBitmapImageRep(cgImage: image)
    }

    private static func capture(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func compose(_ base: NSBitmapImageRep, _ overlay: NSBitmapImageRep, at origin: NSPoint, scale: CGFloat) -> NSBitmapImageRep? {
        let size = NSSize(width: base.pixelsWide, height: base.pixelsHigh)
        guard let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return base }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
        base.draw(in: NSRect(origin: .zero, size: size))
        overlay.draw(in: NSRect(x: origin.x * scale, y: origin.y * scale, width: CGFloat(overlay.pixelsWide), height: CGFloat(overlay.pixelsHigh)))
        NSGraphicsContext.restoreGraphicsState()
        return result
    }

    /// `-PHBenchmark YES`: 60,000 more sample photos; times loading, grouping by day, sorting, searching and
    /// laying out the grid.
    private static func runBenchmark(_ app: AppDelegate) {
        guard defaults.bool(forKey: "PHBenchmark") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let library = app.library!
            library.reload {
                guard let controller = app.windowController else { return }
                let count = library.snapshot.count
                func time(_ label: String, _ body: () -> Void) {
                    let start = Date()
                    body()
                    print(String(format: "BENCHMARK: %@: %.0f ms", label, Date().timeIntervalSince(start) * 1000))
                }
                time("snapshot of \(count) items") { _ = LibrarySnapshot(items: library.snapshot.items) }
                time("timeline content (group by day)") { _ = controller.makeContent() }
                time("sort by title") { _ = library.arranger.sorted(library.snapshot.allIDs, by: .title, ascending: true) }
                time("search \"june\"") { _ = PhotoSearch("june").filter(library.snapshot.allIDs, using: library.arranger) }
                time("memories page") { _ = app.memories.finder.page() }
                time("a month of memory notifications") {
                    _ = MemoryNotifications.plan(finder: app.memories.finder, from: app.memories.today, days: 30, hour: 9, minute: 0)
                }
                time("refresh and lay out the grid") {
                    controller.refresh(keepPosition: false)
                    controller.grid.collectionView.layoutSubtreeIfNeeded()
                }
                time("scroll through the grid") {
                    let height = controller.grid.layout.collectionViewContentSize.height
                    for step in 0..<40 {
                        controller.grid.collectionView.scroll(NSPoint(x: 0, y: height * CGFloat(step) / 40))
                        controller.grid.collectionView.layoutSubtreeIfNeeded()
                    }
                }
                fflush(stdout)
                exit(0)
            }
        }
    }
}
#endif
