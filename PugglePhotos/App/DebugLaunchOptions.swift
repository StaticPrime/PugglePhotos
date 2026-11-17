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

    static func makeSampleSource() -> SamplePhotoSource {
        let access: LibraryAccess = switch defaults.string(forKey: "PHAccess") {
        case "ask": .notDetermined
        case "denied": .denied
        default: .authorized
        }
        let count = defaults.integer(forKey: "PHSampleCount") + (defaults.bool(forKey: "PHBenchmark") ? 60_000 : 0)
        return SamplePhotoSource(today: sampleToday, count: count, access: access)
    }

    /// View settings for sample-library runs, emptied at launch so every run starts the same way.
    static let sampleDefaults: UserDefaults = {
        let name = "com.pugglesoft.PugglePhotos.sample"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

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
            setUp(controller, app: app)
            if defaults.bool(forKey: "PHDebugLayout") { print("PHDebug: window=\(window.windowNumber)"); fflush(stdout) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (defaults.double(forKey: "PHSnapshotDelay") > 0 ? defaults.double(forKey: "PHSnapshotDelay") : 2.6)) {
            snapshot(name, app: app)
        }
    }

    /// `-PHSource library|favorites|videos|recent|albums|album:N|label:N` picks the place;
    /// `-PHViewMode list`, `-PHGrouping month`, `-PHSort title`, `-PHDescending YES`, `-PHZoom 220` and
    /// `-PHSearch text` set how it shows; `-PHSelect 3` (or `3,4,5`) selects photos by position;
    /// `-PHViewer YES` opens the first selected; `-PHCalendar 2019-07` turns the calendar;
    /// `-PHRedate day|between` shows the question asked when photos are dropped; `-PHOpenSheet
    /// changeDate|shortcuts|newLabel` opens a sheet; `-PHShowAbout YES` and `-PHSettings YES` open those windows.
    private static func setUp(_ controller: LibraryWindowController, app: AppDelegate) {
        let library = app.library!
        if let source = defaults.string(forKey: "PHSource") {
            let parts = source.split(separator: ":")
            let index = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            switch parts.first {
            case "favorites": controller.go(to: .favorites)
            case "videos": controller.go(to: .videos)
            case "recent": controller.go(to: .recentlyAdded)
            case "albums": controller.go(to: .allAlbums)
            case "album":
                let albums = library.catalog.albums
                if albums.indices.contains(index - 1) { controller.go(to: .album(albums[index - 1].id)) }
            case "label":
                let labels = library.catalog.labels
                if labels.indices.contains(index - 1) { controller.go(to: .label(labels[index - 1].id)) }
            default: break
            }
        }
        if let mode = defaults.string(forKey: "PHViewMode").flatMap(ViewMode.init(rawValue:)) { controller.setViewMode(mode) }
        if let grouping = defaults.string(forKey: "PHGrouping").flatMap(Grouping.init(rawValue:)) { controller.setGrouping(grouping) }
        if let sort = defaults.string(forKey: "PHSort").flatMap(SortKey.init(rawValue:)) { controller.setSort(sort) }
        if defaults.object(forKey: "PHDescending") != nil { controller.setAscending(!defaults.bool(forKey: "PHDescending")) }
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
        default: break
        }
        if defaults.bool(forKey: "PHShowAbout") { app.showAboutWindow(nil) }
        if defaults.bool(forKey: "PHSettings") { app.showSettings(nil) }
    }

    private static func snapshot(_ name: String, app: AppDelegate) {
        guard let controller = app.windowController, let main = controller.window else {
            print("PHSnapshot: no window")
            exit(1)
        }
        let about = NSApp.windows.first { $0.windowController is AboutWindowController && $0.isVisible }
        let settings = NSApp.windows.first { $0.windowController is SettingsWindowController && $0.isVisible }
        let window = about ?? settings ?? main.attachedSheet ?? main
        guard let view = window.contentView?.superview ?? window.contentView else { exit(1) }
        // The window server's picture of the window shows vibrant sidebars and every SwiftUI view as they really
        // look; drawing the views into a bitmap misses those, so it's only the fallback.
        if let windowImage = windowServerImage(window) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? windowImage.representation(using: .png, properties: [:])?.write(to: url)
            print("PHSnapshot: \(url.path)")
            fflush(stdout)
            exit(0)
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? image.representation(using: .png, properties: [:])?.write(to: url)
        print("PHSnapshot: \(url.path)")
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
