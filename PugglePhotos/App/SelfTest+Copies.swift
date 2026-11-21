#if DEBUG
import AppKit
import PugglePhotosKit
import UniformTypeIdentifiers

extension SelfTest {
    /// Duplicating, deleting, copying and pasting photos: the right-click menu and the Photo and Edit menus offering
    /// them where they work, a copy's name, date, place, favorite and writing, its place in an album in its own order
    /// and in that album's twin, Undo and Redo; the question before deleting, what deleting forgets (even when
    /// something done before is undone), the viewer going on to the next photo, saying no to macOS and refusals;
    /// photos pasted into an album and files pasted as if dropped.
    static func copySteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        let source = library.baseSource as! SamplePhotoSource
        let undo = library.undoManager
        guard let nsWindow = window.window else { return }
        var snapshot: LibrarySnapshot { library.snapshot }
        var catalog: Catalog { library.catalog }
        func allowed(_ action: Selector) -> Bool { window.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
        func name(_ id: PhotoID) -> String { snapshot.item(id)?.fileName ?? "" }
        /// A file name with a copy's number: "IMG_1.HEIC" and 2 make "IMG_1(2).HEIC".
        func numbered(_ name: String, _ number: Int) -> String {
            let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
            return ext.isEmpty ? "\(stem)(\(number))" : "\(stem)(\(number)).\(ext)"
        }
        var before: Set<PhotoID> = []
        func remember() { before = Set(snapshot.allIDs) }
        func newIDs() -> [PhotoID] { snapshot.allIDs.filter { !before.contains($0) } }
        /// One copy made, its name known, the window done saying it's copying.
        func oneCopyMade() -> Bool { newIDs().count == 1 && newIDs().allSatisfy { !name($0).isEmpty } && window.addingStatus == nil }
        func twin(_ album: UUID) -> LibraryAlbum? {
            guard let photosID = catalog.album(album)?.photosAlbumID else { return nil }
            return source.albums.first { $0.id == photosID }
        }
        let duplicateAction = #selector(LibraryWindowController.phDuplicate(_:)), deleteAction = #selector(LibraryWindowController.phDelete(_:))
        let copyAction = #selector(LibraryWindowController.copy(_:)), pasteAction = #selector(LibraryWindowController.paste(_:))
        // A favorite with a note on its back.
        let original = PhotoID("sample-beach20-2")
        var first: PhotoID?
        var second: PhotoID?
        var copyOfCopy: PhotoID?

        // MARK: Duplicate
        step {
            window.go(to: .library)
            window.setViewMode(.gallery)
            nsWindow.makeFirstResponder(window.grid.collectionView)
            window.grid.select([original])
            let titles = window.photoMenu(for: [original]).items.map(\.title)
            check(titles.contains("Duplicate") && titles.contains("Delete…"), "a photo's right-click menu offers Duplicate and Delete…", "\(titles)")
            check(allowed(duplicateAction) && allowed(deleteAction) && allowed(copyAction), "they work on a photo chosen in the gallery")
            check(menuItem("Photo", "Duplicate")?.keyEquivalent == "d" && menuItem("Photo", "Delete…").map { $0.keyEquivalent == "\u{8}" && $0.keyEquivalentModifierMask == .command } == true,
                  "Photo ▸ Duplicate is ⌘D, and Delete… is ⌘⌫")
            check(menuItem("Edit", "Copy")?.action == copyAction && menuItem("Edit", "Paste")?.action == pasteAction, "Edit ▸ Copy and Paste reach the window")
            window.setViewMode(.list)
            window.list.select([original])
            check(window.state.selection == [original] && allowed(duplicateAction) && allowed(deleteAction)
                  && window.browserMenu(for: [original])?.items.contains { $0.action == deleteAction } == true, "and on one chosen in the list")
            window.setViewMode(.gallery)
            window.grid.select([original])
            remember()
            check(choose("Photo", "Duplicate"), "Photo ▸ Duplicate can be chosen")
            wait(until: oneCopyMade)
        }
        step {
            first = newIDs().first
            guard let copy = first, let copied = snapshot.item(copy), let item = snapshot.item(original) else {
                check(false, "Duplicate makes a copy")
                return
            }
            let expected = numbered(name(original), 1)
            check(name(copy) == expected && source.copyNames[copy] == expected, "the copy's file is named after its photo's, numbered: “\(expected)”", name(copy))
            check(copied.date == item.date && copied.kind == item.kind && copied.isFavorite && copied.location == item.location
                  && copied.pixelWidth == item.pixelWidth && copied.pixelHeight == item.pixelHeight,
                  "it's taken when and where its photo was, a favorite as that is")
            check(!catalog.details(original).note.isEmpty && catalog.details(copy) == catalog.details(original), "it has its photo's caption, note and labels")
            check(window.state.selection == [copy], "and it's picked out", "\(window.state.selection)")
            check(undo.undoActionName == "Duplicate", "Duplicate is a step to undo", undo.undoActionName)
            window.setSelection([original])
            remember()
            window.phDuplicate(nil)
            wait(until: oneCopyMade)
        }
        step {
            second = newIDs().first
            let expected = numbered(name(original), 2)
            check(second.map(name) == expected, "another copy takes the next number: “\(expected)”", second.map(name) ?? "none")
            guard let first else { return }
            window.setSelection([first])
            remember()
            window.phDuplicate(nil)
            wait(until: oneCopyMade)
        }
        step {
            copyOfCopy = newIDs().first
            let expected = first.map { numbered(name($0), 1) } ?? "?"
            check(copyOfCopy.map(name) == expected, "a copy of a copy is numbered again: “\(expected)”", copyOfCopy.map(name) ?? "none")
        }

        // MARK: Duplicate in an album in its own order
        var best: UUID?
        var albumCopy: PhotoID?
        var albumCount = 0
        step {
            best = catalog.albums.first { $0.title == "Best of 2025" }?.id
            guard let best, let album = catalog.album(best), album.order == .custom, album.items.count >= 2 else {
                check(false, "the sample album in its own order is there")
                return
            }
            albumCount = album.items.count
            window.go(to: .album(best))
            window.setSelection([album.items[0]])
            remember()
            check(choose("Photo", "Duplicate"), "Duplicate works in an album")
            wait { oneCopyMade() && twin(best)?.items.count == albumCount + 1 }
        }
        step {
            guard let best, let album = catalog.album(best) else { return }
            albumCopy = newIDs().first
            check(album.items.count == albumCount + 1 && album.items[1] == albumCopy, "in an album in its own order, the copy goes right after its photo",
                  "\(album.items.prefix(3))")
            check(twin(best)?.items == album.items, "and the same in its twin in the Photos library")
            check(albumCopy.map { window.content.allIDs.contains($0) && window.state.selection == [$0] } == true, "and it shows there, picked out")
            undo.undo()
            wait { albumCopy.map { !snapshot.contains($0) } == true && twin(best)?.items.count == albumCount }
        }
        step {
            guard let best, let albumCopy else { return }
            check(!snapshot.contains(albumCopy) && source.items[albumCopy] == nil, "Undo deletes the copy from the library")
            check(catalog.album(best)?.items.contains(albumCopy) == false && twin(best)?.items.contains(albumCopy) == false
                  && catalog.photos[albumCopy] == nil, "and from the album, forgetting what was written on it")
            check(undo.redoActionName == "Duplicate", "Redo can make it again", undo.redoActionName)
            remember()
            undo.redo()
            wait { oneCopyMade() && twin(best)?.items.count == albumCount + 1 }
        }
        step {
            guard let best else { return }
            check(newIDs().count == 1 && catalog.album(best)?.items[1] == newIDs().first, "Redo makes it again, in the same place")
            // ⌘⌫ that reaches the grid itself (with Delete… off) doesn't do what Delete alone does there.
            let count = catalog.album(best)?.items.count
            window.grid.select(Array(window.content.allIDs.prefix(1)))
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: nsWindow.windowNumber,
                                            context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) {
                window.grid.collectionView.keyDown(with: event)
            }
            check(catalog.album(best)?.items.count == count, "⌘⌫ never just takes a photo out of the album")
            // None of it works in a book.
            window.setViewMode(.book)
            check(window.isShowingBook && !allowed(copyAction) && !allowed(pasteAction) && !allowed(duplicateAction) && !allowed(deleteAction),
                  "none of them work in a book")
            window.setViewMode(.gallery)
            window.go(to: .library)
        }

        // MARK: Delete
        var captioned: PhotoID?
        var undoBefore = ""
        step {
            // Something written on another photo first, to undo after the copy is deleted.
            captioned = snapshot.allIDs.first { $0.rawValue.hasPrefix("sample-garden26-") && catalog.details($0).caption.isEmpty }
            if let captioned { library.edit("Caption") { $0.setCaption("Tomatoes, at last", for: [captioned]) } }
            guard let copyOfCopy else { return }
            window.setSelection([copyOfCopy])
            check(choose("Photo", "Delete…"), "Photo ▸ Delete… can be chosen")
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            let words = texts(in: nsWindow.attachedSheet?.contentView)
            let title = copyOfCopy.map(library.title(of:)) ?? "?"
            check(words.contains("Delete “\(title)” from your library?") && words.contains { $0.contains("Recently Deleted") },
                  "Delete… asks first, naming the photo", "\(words)")
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            check(copyOfCopy.map { snapshot.contains($0) && source.items[$0] != nil } == true, "Cancel deletes nothing")
            window.phDelete(nil)
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            undoBefore = undo.undoActionName
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            wait { copyOfCopy.map { !snapshot.contains($0) } == true }
        }
        step {
            guard let copyOfCopy else { return }
            check(!snapshot.contains(copyOfCopy) && source.items[copyOfCopy] == nil, "Delete deletes the photo from the library")
            check(catalog.photos[copyOfCopy] == nil && !catalog.albums.contains { $0.items.contains(copyOfCopy) } && library.deleted.contains(copyOfCopy),
                  "and forgets what was written about it")
            check(undo.undoActionName == undoBefore && undoBefore == "Caption", "deleting isn't a step Undo takes back", undo.undoActionName)
            undo.undo()
            check(captioned.map { catalog.details($0).caption.isEmpty } == true && catalog.photos[copyOfCopy] == nil,
                  "undoing what was done before it brings back nothing of a deleted photo")
        }
        var expectedNext: PhotoID?
        step {
            guard let second else { return }
            window.openViewer(second)
            let sequence = window.viewerSequence
            if let index = sequence.firstIndex(of: second), index + 1 < sequence.count { expectedNext = sequence[index + 1] }
            check(window.state.viewerID == second && allowed(deleteAction) && allowed(duplicateAction), "Delete… and Duplicate work on the photo in the viewer")
            check(window.viewerMenu(for: second)?.items.contains { $0.action == deleteAction } == true, "and are on its right-click menu")
            window.phDelete(nil)
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            wait { second.map { !snapshot.contains($0) } == true && window.state.viewerID != second }
        }
        step {
            check(second.map { !snapshot.contains($0) } == true, "a photo can be deleted from the viewer")
            check(expectedNext != nil && window.state.viewerID == expectedNext, "which goes on to the next photo",
                  "\(String(describing: window.state.viewerID)), not \(String(describing: expectedNext))")
            window.closeViewer()
            guard let first else { return }
            source.declineNextDelete = true
            window.delete([first])
            wait(upTo: 1) { nsWindow.attachedSheet != nil }
        }
        step {
            check(nsWindow.attachedSheet == nil && first.map(snapshot.contains) == true, "saying no when macOS asks deletes nothing, and nothing more is said")
            guard let first else { return }
            source.refuseNextChange = true
            window.delete([first])
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            let words = texts(in: nsWindow.attachedSheet?.contentView)
            check(words.contains("It couldn’t be deleted from your Photos library.") && first.map(snapshot.contains) == true,
                  "a deletion the library refuses says so", "\(words)")
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet) }
            guard let first else { return }
            source.refuseNextChange = true
            window.setSelection([first])
            remember()
            window.phDuplicate(nil)
            wait { nsWindow.attachedSheet != nil }
        }
        step {
            let words = texts(in: nsWindow.attachedSheet?.contentView)
            check(words.contains { $0.hasSuffix("couldn’t be copied.") } && newIDs().isEmpty, "a copy the library refuses says so", "\(words)")
            if let sheet = nsWindow.attachedSheet { nsWindow.endSheet(sheet) }
            // While typing, ⌘⌫ deletes words, not photos.
            let typing = NSTextView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            window.dropZone.addSubview(typing)
            nsWindow.makeFirstResponder(typing)
            check(!allowed(deleteAction) && !allowed(duplicateAction), "Delete… and Duplicate are off while typing")
            typing.removeFromSuperview()
            nsWindow.makeFirstResponder(window.grid.collectionView)
        }

        // MARK: Copy and Paste
        let garden = [PhotoID("sample-garden22-1"), PhotoID("sample-garden22-2")]
        var snow: UUID?
        var snowCount = 0
        step {
            window.go(to: .library)
            nsWindow.makeFirstResponder(window.grid.collectionView)
            window.setSelection([])
            check(!allowed(copyAction), "Copy is off with nothing chosen")
            window.setSelection(garden)
            check(allowed(copyAction), "and on with photos chosen")
            window.copy(nil)
            check(PhotoDrag.ids(from: PhotoClipboard.pasteboard) == garden && PhotoClipboard.pasteboard !== NSPasteboard.general,
                  "Copy puts them on the clipboard (the self-test's own)")
            window.go(to: .memories)
            check(!allowed(pasteAction), "photos can't be pasted on Memories")
            snow = catalog.albums.first { $0.title == "Snow Days" }?.id
            guard let snow else {
                check(false, "the sample's Snow Days album is there")
                return
            }
            snowCount = catalog.album(snow)?.items.count ?? 0
            window.go(to: .album(snow))
            check(allowed(pasteAction), "but can in an album")
            remember()
            window.paste(nil)
            wait { newIDs().count == 2 && newIDs().allSatisfy { !name($0).isEmpty } && window.addingStatus == nil && twin(snow)?.items.count == snowCount + 2 }
        }
        step {
            guard let snow, let album = catalog.album(snow) else { return }
            let pasted = newIDs()
            check(pasted.count == 2 && Set(album.items.suffix(2)) == Set(pasted) && twin(snow)?.items == album.items,
                  "Paste makes copies of them at the end of the album, and its twin")
            check(Set(pasted.map(name)) == Set(garden.map { numbered(name($0), 1) }), "named as copies", "\(pasted.map(name))")
            check(garden.allSatisfy(snapshot.contains) && !album.items.contains(garden[0]), "the photos copied stay where they were")
            check(undo.undoActionName == "Paste", "Paste is a step to undo", undo.undoActionName)
            undo.undo()
            wait { pasted.allSatisfy { !snapshot.contains($0) } && twin(snow)?.items.count == snowCount }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PugglePhotos Paste Test \(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("Pasted Picnic.png")
        step {
            check(newIDs().isEmpty && snow.flatMap { catalog.album($0)?.items.count } == snowCount, "Undo takes the pasted copies away again")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            check(writeTestImage(file, type: .png, width: 40, height: 30), "(the file to paste is made)")
            let pasteboard = PhotoClipboard.pasteboard
            pasteboard.clearContents()
            pasteboard.writeObjects([file as NSURL])
            window.go(to: .favorites)
            check(allowed(pasteAction), "files copied in the Finder can be pasted")
            remember()
            window.paste(nil)
            wait(until: oneCopyMade)
        }
        step {
            let added = newIDs()
            check(added.count == 1 && added.allSatisfy { snapshot.item($0)?.isFavorite == true && name($0) == "Pasted Picnic.png" },
                  "and go in as if dropped there: on Favorites, as a favorite", "\(added.map(name))")
            undo.undo()
            wait { added.allSatisfy { !snapshot.contains($0) } }
        }
        step {
            check(newIDs().isEmpty, "Undo takes a pasted file out again")
            window.go(to: .library)
            try? FileManager.default.removeItem(at: folder)
            PhotoClipboard.pasteboard.clearContents()
        }
    }
}
#endif
