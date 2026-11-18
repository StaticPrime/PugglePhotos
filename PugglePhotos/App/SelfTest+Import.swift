#if DEBUG
import AppKit
import PugglePhotosKit
import UniformTypeIdentifiers

/// A drag as AppKit hands it to what it's over, for the self-test: what's dragged, on a pasteboard of its own, and
/// where the pointer is (in the window).
final class TestDrag: NSObject, NSDraggingInfo {
    private static var count = 50_000
    private static var pasteboards: [NSPasteboard] = []
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingSequenceNumber: Int
    private weak var window: NSWindow?

    init(writing objects: [NSPasteboardWriting], at location: NSPoint = .zero, in window: NSWindow? = nil) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PugglePhotos self-test \(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
        Self.pasteboards.append(pasteboard)
        draggingPasteboard = pasteboard
        draggingLocation = location
        Self.count += 1
        draggingSequenceNumber = Self.count
        self.window = window
    }

    /// Files dragged in from another app.
    static func files(_ urls: [URL], at location: NSPoint = .zero, in window: NSWindow? = nil) -> TestDrag {
        TestDrag(writing: urls.map { $0 as NSURL }, at: location, in: window)
    }

    /// Photos dragged inside PugglePhotos.
    static func photos(_ ids: [PhotoID], at location: NSPoint = .zero, in window: NSWindow? = nil) -> TestDrag {
        TestDrag(writing: ids.map(PhotoDrag.item), at: location, in: window)
    }

    static func releasePasteboards() {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards = []
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

extension SelfTest {
    /// A small picture file, with a camera's date inside it or none.
    static func writeTestImage(_ url: URL, type: UTType, width: Int, height: Int, cameraDate: (time: String, offset: String)? = nil) -> Bool {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        context.setFillColor(CGColor(srgbRed: 0.91, green: 0.36, blue: 0.48, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        var properties: [CFString: Any] = [:]
        if let cameraDate {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: cameraDate.time,
                                                          kCGImagePropertyExifOffsetTimeOriginal: cameraDate.offset]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// The words in a window's views, to read an alert by.
    static func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { texts(in: $0) }
    }

    /// Photos and videos dragged in from other apps: what counts, how each file is read and dated, the middle
    /// lighting up and taking them, the sidebar taking them on Favorites, an album, a label and Albums, copies
    /// already in the library (skipped or added again), Undo and Redo, a refusal; and photos dragged from Library,
    /// Favorites, Videos and Recently Added onto an album in the sidebar.
    static func importSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        let source = library.source as! SamplePhotoSource
        guard let nsWindow = window.window else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PugglePhotos Drop Test \(UUID().uuidString)", isDirectory: true)
        let screenshot = folder.appendingPathComponent("Screenshot of the Lake.png")
        let taken = folder.appendingPathComponent("IMG_2104.JPG")
        let movie = folder.appendingPathComponent("Pug Zoomies.mov")
        let notes = folder.appendingPathComponent("Packing List.txt")
        let broken = folder.appendingPathComponent("Half Copied.jpg")
        let trip = folder.appendingPathComponent("Trip", isDirectory: true)
        let ferry = trip.appendingPathComponent("Ferry.png")
        let more = (1...5).map { folder.appendingPathComponent("Sunset \($0).png") }
        let onDisk = Calendar.current.date(from: DateComponents(year: 2024, month: 3, day: 5, hour: 10))!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let shot = utc.date(from: DateComponents(year: 2021, month: 6, day: 12, hour: 13, minute: 30))!
        var movieMade = false
        var dropped: DroppedFiles?
        var before: Set<PhotoID> = []
        var copyID: PhotoID?
        var dragAlbum: UUID?
        func remember() { before = Set(library.snapshot.allIDs) }
        func newIDs() -> [PhotoID] { library.snapshot.allIDs.filter { !before.contains($0) } }
        var outline: NSOutlineView { window.sidebar.outlineView }
        func node(_ where: (SidebarNode) -> Bool) -> SidebarNode? {
            (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? SidebarNode }.first(where: `where`)
        }
        func node(_ place: LibrarySource) -> SidebarNode? { node { $0.source == place } }
        func importable(_ urls: [URL]) -> Int { FileDrop.importableCount(TestDrag.files(urls).draggingPasteboard) }
        func middle() -> NSPoint {
            let zone = window.dropZone
            return zone.convert(NSPoint(x: zone.bounds.midX, y: zone.bounds.midY), to: nil)
        }
        func dropOnSidebar(_ urls: [URL], _ row: SidebarNode?) -> Bool {
            guard let row else { return false }
            let drag = TestDrag.files(urls, in: nsWindow)
            return window.sidebar.outlineView(outline, validateDrop: drag, proposedItem: row, proposedChildIndex: NSOutlineViewDropOnItemIndex) == .copy
                && window.sidebar.outlineView(outline, acceptDrop: drag, item: row, childIndex: NSOutlineViewDropOnItemIndex)
        }

        step {
            try? FileManager.default.createDirectory(at: trip, withIntermediateDirectories: true)
            var made = writeTestImage(screenshot, type: .png, width: 64, height: 48)
                && writeTestImage(taken, type: .jpeg, width: 80, height: 60, cameraDate: ("2021:06:12 15:30:00", "+02:00"))
                && writeTestImage(ferry, type: .png, width: 40, height: 30)
            for url in more { made = made && writeTestImage(url, type: .png, width: 30, height: 40) }
            try? "Socks, sunscreen, the good towel".write(to: notes, atomically: true, encoding: .utf8)
            try? Data("not a picture yet".utf8).write(to: broken)
            try? FileManager.default.setAttributes([.creationDate: onDisk, .modificationDate: onDisk], ofItemAtPath: screenshot.path)
            check(made, "(the files to drop are made)")
            Task { movieMade = await SampleVideo.make(at: movie, scene: .pug, seed: 7) }
            wait(upTo: 30) { movieMade }
        }
        step {
            check(importable([screenshot, taken, movie, notes]) == 3, "of the files dragged in, only the photos and videos count",
                  "\(importable([screenshot, taken, movie, notes]))")
            check(importable([notes]) == 0, "a drag of other files isn't taken")
            check(importable([trip]) == 1, "a folder with photos in it is")
            check(FileDrop.importableCount(TestDrag.photos(Array(library.snapshot.allIDs.prefix(2))).draggingPasteboard) == 0,
                  "photos dragged inside PugglePhotos aren't files to add")
            Task { dropped = await FileImport.read([screenshot, taken, movie, notes, broken, trip]) }
            wait { dropped != nil }
        }
        step {
            guard let dropped else {
                check(false, "the dropped files are read")
                return
            }
            let files = Dictionary(dropped.files.map { ($0.name, $0) }) { first, _ in first }
            check(dropped.files.map(\.name) == ["Screenshot of the Lake.png", "IMG_2104.JPG", "Pug Zoomies.mov", "Ferry.png"],
                  "a drop is read in order, folders all the way down", "\(dropped.files.map(\.name))")
            check(files["IMG_2104.JPG"].map { $0.dateIsInFile && abs($0.date.timeIntervalSince(shot)) < 1 } == true,
                  "a photo is dated as its camera says, in the camera's time zone", "\(String(describing: files["IMG_2104.JPG"]?.date))")
            check(files["Screenshot of the Lake.png"].map { !$0.dateIsInFile && abs($0.date.timeIntervalSince(onDisk)) < 1 && $0.pixelSize == CGSize(width: 64, height: 48) } == true,
                  "one that doesn't say is dated when its file was made")
            check(files["Pug Zoomies.mov"].map { $0.kind == .video && $0.duration > 0.5 } == true, "a video is a video, with its length")
            check(dropped.unreadable == ["Half Copied.jpg"], "a file that only looks like a photo is noticed", "\(dropped.unreadable)")
        }

        // MARK: The middle
        step {
            window.go(to: .library)
            window.setViewMode(.gallery)
            let zone = window.dropZone
            let drag = TestDrag.files([screenshot, taken], at: middle(), in: nsWindow)
            check(zone.draggingEntered(drag) == .copy && zone.shownTitle == "Add to Library" && drag.numberOfValidItemsForDrop == 2,
                  "photos dragged over the library light it up: “Add to Library”", "\(String(describing: zone.shownTitle))")
            zone.draggingExited(drag)
            check(zone.shownTitle == nil, "and the light goes out when they leave")
            check(zone.draggingEntered(TestDrag.files([notes], at: middle(), in: nsWindow)) == [] && zone.shownTitle == nil,
                  "other files don't light it up")
            window.go(to: .favorites)
            check(zone.draggingUpdated(TestDrag.files([taken], at: middle(), in: nsWindow)) == .copy && zone.shownTitle == "Add to Favorites",
                  "over Favorites it says “Add to Favorites”")
            if let beach = library.catalog.albums.first(where: { $0.title == "Beach Trips" }) {
                window.go(to: .album(beach.id))
                check(zone.draggingUpdated(TestDrag.files([taken], at: middle(), in: nsWindow)) == .copy && zone.shownTitle == "Add to “Beach Trips”",
                      "over an album, that album", "\(String(describing: zone.shownTitle))")
            }
            window.go(to: .memories)
            check(zone.draggingUpdated(TestDrag.files([taken], at: middle(), in: nsWindow)) == [] && zone.shownTitle == nil,
                  "Memories don't take files")
            zone.draggingExited(nil)
            window.go(to: .allAlbums)
        }
        step {
            // On the album covers: a cover takes them into its album; the New Album tile, into a new one.
            let covers = window.albums.collectionView!
            if let first = covers.item(at: IndexPath(item: 0, section: 0))?.view, let id = window.albums.summaries.first?.id,
               let last = covers.item(at: IndexPath(item: window.albums.summaries.count, section: 0))?.view {
                let onCover = window.dropZone.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), from: first)
                let onNew = window.dropZone.convert(NSPoint(x: last.bounds.midX, y: last.bounds.midY), from: last)
                check(window.fileDropTarget(at: onCover) == .album(id) && window.fileDropTarget(at: onNew) == .newAlbum,
                      "on the album covers, files go into the album dropped on, or a new one")
            } else {
                check(false, "the album covers are showing")
            }
            window.go(to: .library)
        }
        step {
            remember()
            check(window.dropZone.performDragOperation(TestDrag.files([screenshot, taken], at: middle(), in: nsWindow)),
                  "photos can be dropped on the library")
            wait { newIDs().count == 2 && window.addingStatus == nil }
        }
        step {
            let added = newIDs().compactMap { library.snapshot.item($0) }
            check(added.count == 2 && added.contains { abs($0.date.timeIntervalSince(shot)) < 1 } && added.contains { abs($0.date.timeIntervalSince(onDisk)) < 1 },
                  "dropped photos go into the library, each on the day it was taken", "\(added.map(\.date))")
            check(!added.isEmpty && added.allSatisfy { library.recentlyAdded.contains($0.id) }, "they show in Recently Added")
            check(!added.isEmpty && Set(window.state.selection) == Set(added.map(\.id)), "and they're picked out where they landed",
                  "\(window.state.selection.count) picked")
            check(library.undoManager.undoMenuItemTitle == "Undo Add 2 Photos", "Undo can take them out", library.undoManager.undoMenuItemTitle)
            let ids = added.map(\.id)
            library.undoManager.undo()
            wait { ids.allSatisfy { !library.snapshot.contains($0) } }
        }
        step {
            check(newIDs().isEmpty, "Undo takes dropped photos out of the library again")
            check(library.undoManager.redoMenuItemTitle == "Redo Add 2 Photos", "and Redo can put them back", library.undoManager.redoMenuItemTitle)
            library.undoManager.redo()
            wait { newIDs().count == 2 && newIDs().allSatisfy { library.snapshot.item($0)?.fileName != nil } }
        }
        step {
            check(newIDs().count == 2, "Redo adds them again")
            copyID = newIDs().first { library.snapshot.item($0)?.fileName == "IMG_2104.JPG" }
        }

        // MARK: Copies already in the library
        step {
            remember()
            window.dropFiles([taken], on: .library)
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            let words = texts(in: nsWindow.attachedSheet?.contentView)
            check(words.contains("“IMG_2104.JPG” is already in your library."), "a photo already in the library is noticed before it's added again",
                  "\(words)")
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            wait(upTo: 1) { window.state.selection == [copyID].compactMap { $0 } }
        }
        step {
            check(newIDs().isEmpty, "Skip leaves it as it is")
            check(copyID.map { window.state.selection == [$0] } == true, "and picks out the one already there")
            guard let beach = library.catalog.albums.first(where: { $0.title == "Beach Trips" }) else { return }
            window.dropFiles([taken], on: .album(beach.id))
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            wait(upTo: 2) { library.catalog.albums.first { $0.title == "Beach Trips" }?.items.contains(copyID ?? PhotoID("")) == true }
        }
        step {
            let beach = library.catalog.albums.first { $0.title == "Beach Trips" }
            check(newIDs().isEmpty && beach?.items.contains(copyID ?? PhotoID("")) == true,
                  "skipped, a photo already in the library still goes into the album it was dropped on")
            check(library.undoManager.undoMenuItemTitle == "Undo Add to Album", "as a step to undo", library.undoManager.undoMenuItemTitle)
            library.undoManager.undo()
            check(library.catalog.albums.first { $0.title == "Beach Trips" }?.items.contains(copyID ?? PhotoID("")) == false
                  && copyID.map(library.snapshot.contains) == true, "Undo takes it back out of the album, leaving it in the library")
            window.dropFiles([taken], on: .library)
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            wait { newIDs().count == 1 }
        }
        step {
            check(newIDs().count == 1, "Add Again adds a second copy")
        }

        // MARK: The sidebar
        step {
            remember()
            check(dropOnSidebar([ferry, movie], node(.favorites)), "photos and videos can be dropped on Favorites in the sidebar")
            wait { newIDs().count == 2 && newIDs().allSatisfy { library.snapshot.item($0)?.isFavorite == true } }
        }
        step {
            let added = newIDs()
            check(added.count == 2 && added.allSatisfy { library.snapshot.item($0)?.isFavorite == true }, "and they're added as favorites")
            check(added.contains { library.snapshot.item($0)?.kind == .video }, "the video too")
            let drag = TestDrag.files([notes], in: nsWindow)
            check(node(.favorites).map { window.sidebar.outlineView(outline, validateDrop: drag, proposedItem: $0, proposedChildIndex: -1) } == [],
                  "other files can't be dropped there")
            check(node(.memories).map { window.sidebar.outlineView(outline, validateDrop: TestDrag.files([more[0]], in: nsWindow), proposedItem: $0, proposedChildIndex: -1) } == [],
                  "and nothing can be dropped on Memories")
            remember()
            guard let lake = library.catalog.albums.first(where: { $0.title.contains("Lake") }) ?? library.catalog.albums.first else { return }
            check(dropOnSidebar([more[0]], node(.album(lake.id))), "photos can be dropped on an album in the sidebar")
            wait { newIDs().count == 1 }
        }
        step {
            let lake = library.catalog.albums.first { $0.title.contains("Lake") } ?? library.catalog.albums.first
            check(newIDs().count == 1 && newIDs().allSatisfy { lake?.items.contains($0) == true }, "and go into the library and the album")
            remember()
            guard let label = library.catalog.labels.first else { return }
            check(dropOnSidebar([more[1]], node(.label(label.id))), "on a label")
            wait { newIDs().count == 1 && library.membership.photos(labeled: label.id).contains(newIDs()[0]) }
        }
        step {
            if let label = library.catalog.labels.first {
                check(newIDs().count == 1 && library.membership.photos(labeled: label.id).contains(newIDs()[0]), "and get the label")
            }
            remember()
            let albums = library.catalog.albums.count
            check(dropOnSidebar([more[2], more[3]], node { $0.kind == .heading("Albums") }), "and on Albums")
            wait { library.catalog.albums.count == albums + 1 && newIDs().count == 2 }
        }
        step {
            let made = library.catalog.albums.last
            check(newIDs().count == 2 && made.map { Set($0.items) == Set(newIDs()) } == true, "which makes a new album of them")
            if made != nil { library.undoManager.undo() }
            wait { newIDs().isEmpty }
        }
        step {
            check(newIDs().isEmpty, "Undo takes the photos and their new album away again")
            window.window?.makeFirstResponder(window.grid.collectionView)
            source.refuseNextChange = true
            remember()
            window.dropFiles([more[4]], on: .library)
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            let words = texts(in: nsWindow.attachedSheet?.contentView)
            check(newIDs().isEmpty && words.contains("“Sunset 5.png” couldn’t be added."), "a drop the library refuses adds nothing, and says so", "\(words)")
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet) }
        }

        // MARK: Dragging photos onto an album, from every part of the library
        step {
            dragAlbum = library.newAlbum(title: "Dragged Here")
            window.window?.makeFirstResponder(window.grid.collectionView)
        }
        for (place, name) in [(LibrarySource.library, "Library"), (.favorites, "Favorites"), (.videos, "Videos"), (.recentlyAdded, "Recently Added")] {
            step {
                window.go(to: place)
                window.setViewMode(.gallery)
                let grid = window.grid
                guard let dragAlbum, let row = node(.album(dragAlbum)), let first = window.content.sections.first?.items.first,
                      let item = grid.collectionView(grid.collectionView, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) as? NSPasteboardItem else {
                    check(false, "a photo can be dragged from \(name)")
                    return
                }
                let drag = TestDrag(writing: [item], in: nsWindow)
                let taken = window.sidebar.outlineView(outline, validateDrop: drag, proposedItem: row, proposedChildIndex: -1) == .copy
                    && window.sidebar.outlineView(outline, acceptDrop: drag, item: row, childIndex: -1)
                check(taken && library.catalog.album(dragAlbum)?.items.contains(first) == true,
                      "a photo dragged from \(name) onto an album in the sidebar goes into it")
            }
        }
        step {
            window.go(to: .library)
            TestDrag.releasePasteboards()
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
#endif
