import AppKit
import PugglePhotosKit

/// The pasteboard Copy and Paste use: the system's, or one of PugglePhotos' own while the self-test or the sweep
/// runs, so they never touch what the person copied.
enum PhotoClipboard {
    static var pasteboard: NSPasteboard { SelfTestMode.isRunning ? testPasteboard : .general }
    static let testPasteboard = NSPasteboard(name: NSPasteboard.Name("com.pugglesoft.PugglePhotos.test-clipboard"))
}

/// Copies of photos being made, kept to undo and redo as one step: a Duplicate, or a Paste.
final class CopyStep {
    let originals: [PhotoID]
    let target: FileDropTarget
    /// Whether each copy goes right after its original in an album (Duplicate), or they all go at its end (Paste).
    let besideOriginals: Bool
    let actionName: String
    /// The copies, once they're made (nil until then).
    var copies: [CopiedPhoto]?
    /// The album made for them, when they were pasted on All Albums with no album picked.
    var album: UUID?
    var isUndone = false

    init(originals: [PhotoID], target: FileDropTarget, besideOriginals: Bool, actionName: String) {
        self.originals = originals
        self.target = target
        self.besideOriginals = besideOriginals
        self.actionName = actionName
    }
}

// MARK: Duplicating, deleting, copying and pasting photos

extension LibraryWindowController {
    /// The photos Duplicate, Delete and Copy act on: those chosen in the grid or the list, or the one in the viewer,
    /// as long as every one is in the library (none from an album shared with you). Never photos in a book.
    var libraryTargets: [PhotoID] {
        guard !isShowingBook, library.access == .authorized else { return [] }
        let ids = targetIDs
        return ids.allSatisfy(library.snapshot.inLibrary) ? ids : []
    }

    /// Where copies go: into what's showing (an album, a label, Favorites, or just the library), as files dropped
    /// there do; on All Albums, into the album picked, or else a new one. Nil where photos can't go.
    var pasteTarget: FileDropTarget? {
        guard library.access == .authorized, library.hasLoaded, !isShowingBook else { return nil }
        switch state.source {
        case .library, .videos, .recentlyAdded: return .library
        case .favorites: return .favorites
        case let .album(id): return library.catalog.album(id) != nil ? .album(id) : nil
        case let .label(id): return library.catalog.label(id) != nil ? .label(id) : nil
        case .allAlbums: return albums.selectedAlbum.map { .album($0) } ?? .newAlbum
        case .memories, .memory, .journal, .map, .sharedAlbum: return nil
        }
    }

    /// Whether there's something to paste here: photos copied in PugglePhotos, or files copied elsewhere.
    var canPaste: Bool {
        let pasteboard = PhotoClipboard.pasteboard
        return pasteTarget != nil && (PhotoDrag.holdsPhotos(pasteboard) || pasteboard.availableType(from: [.fileURL]) != nil)
    }

    // MARK: Commands

    /// Makes a copy of each chosen photo where it is; in an album, each copy goes right after its photo.
    @objc func phDuplicate(_ sender: Any?) {
        let ids = libraryTargets
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        makeCopies(of: ids, into: pasteTarget ?? .library, besideOriginals: true, actionName: "Duplicate")
    }

    /// Asks, then deletes the chosen photos from the Photos library.
    @objc func phDelete(_ sender: Any?) {
        let ids = libraryTargets
        guard !ids.isEmpty, let window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = deleteQuestion(ids)
        alert.informativeText = ids.count == 1
            ? "It’s deleted from your Photos library and from every album, along with its caption, note and labels here. This can’t be undone in PugglePhotos; your Photos library keeps it in Recently Deleted for 30 days."
            : "They’re deleted from your Photos library and from every album, along with their captions, notes and labels here. This can’t be undone in PugglePhotos; your Photos library keeps them in Recently Deleted for 30 days."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            delete(ids)
        }
    }

    /// Puts the chosen photos on the clipboard, to paste copies of them somewhere else.
    @objc func copy(_ sender: Any?) {
        let ids = libraryTargets
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = PhotoClipboard.pasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(ids.map(PhotoDrag.item))
    }

    /// Makes copies of the photos on the clipboard here. Files copied elsewhere, in the Finder say, are added here as
    /// if they'd been dropped.
    @objc func paste(_ sender: Any?) {
        let pasteboard = PhotoClipboard.pasteboard
        guard let target = pasteTarget else {
            NSSound.beep()
            return
        }
        if PhotoDrag.holdsPhotos(pasteboard) {
            // Photos deleted since they were copied have nothing left to copy.
            let ids = PhotoDrag.ids(from: pasteboard).filter { library.snapshot.inLibrary($0) && !library.deleted.contains($0) }
            guard !ids.isEmpty else {
                NSSound.beep()
                return
            }
            makeCopies(of: ids, into: target, besideOriginals: false, actionName: "Paste")
            return
        }
        guard FileDrop.importableCount(pasteboard) > 0 else {
            NSSound.beep()
            return
        }
        dropFiles(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [], on: target)
    }

    // MARK: Deleting

    /// "Delete “First jump off the dock” from your library?", or "Delete 3 photos from your library?"
    private func deleteQuestion(_ ids: [PhotoID]) -> String {
        if ids.count == 1, let id = ids.first {
            let title = library.title(of: id)
            if !title.isEmpty { return "Delete “\(title)” from your library?" }
            return "Delete this \(kinds(of: ids, plural: false)) from your library?"
        }
        return "Delete \(library.formatting.number(ids.count)) \(kinds(of: ids, plural: true)) from your library?"
    }

    /// Deletes photos from the library. If the viewer was showing one of them, it goes on to the next photo.
    func delete(_ ids: [PhotoID]) {
        let going = Set(ids)
        var next: PhotoID?
        if let shown = state.viewerID, going.contains(shown) {
            let sequence = viewerSequence
            if let index = sequence.firstIndex(of: shown) {
                next = sequence[index...].first { !going.contains($0) } ?? sequence[..<index].last { !going.contains($0) }
            }
        }
        library.deletePhotos(ids) { [weak self] deleted in
            guard let self, deleted, let next, library.snapshot.contains(next) else { return }
            openViewer(next)
        }
    }

    /// "photo", "videos", "photos and videos": what some photos are, for a sentence.
    private func kinds(of ids: [PhotoID], plural: Bool) -> String {
        let counts = library.snapshot.counts(of: ids)
        if counts.photos == 0, counts.videos > 0 { return plural ? "videos" : "video" }
        if counts.videos == 0 { return plural ? "photos" : "photo" }
        return "photos and videos"
    }

    // MARK: Making copies

    /// Makes copies of photos and puts them where they're going, as one step to undo: Undo deletes the copies again
    /// (macOS asks first) and Redo makes them again.
    func makeCopies(of ids: [PhotoID], into target: FileDropTarget, besideOriginals: Bool, actionName: String) {
        let step = CopyStep(originals: ids, target: target, besideOriginals: besideOriginals, actionName: actionName)
        let undo = library.undoManager
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.undoCopies(step) }
        }
        undo.setActionName(actionName)
        let total = ids.count
        addingStatus = total == 1 ? "Copying a \(kinds(of: ids, plural: false))…" : "Copying \(library.formatting.number(total)) \(kinds(of: ids, plural: true))…"
        library.duplicate(ids, progress: { [weak self] done in
            guard let self, done < total else { return }
            addingStatus = "Copying \(library.formatting.number(done)) of \(library.formatting.number(total))…"
        }) { [weak self] copies in
            guard let self else { return }
            addingStatus = nil
            step.copies = copies
            // Undone while they were being made: they're deleted now they're made.
            if step.isUndone {
                library.deletePhotos(copies.map(\.copy))
                return
            }
            placeCopies(step)
        }
    }

    /// Puts copies where they're going, as part of their step's own undo, then picks them out.
    private func placeCopies(_ step: CopyStep) {
        guard let copies = step.copies, !copies.isEmpty else { return }
        let ids = copies.map(\.copy)
        let undo = library.undoManager
        undo.disableUndoRegistration()
        switch step.target {
        case .library: break
        case .favorites: library.setFavorite(ids, true)
        case let .album(id):
            if step.besideOriginals { library.addCopies(copies, toAlbum: id) } else { library.addToAlbum(ids, album: id) }
        case let .label(id): library.edit("Add Label") { $0.setLabel(id, on: ids, true) }
        case .newAlbum: step.album = library.newAlbum(items: ids)
        }
        undo.enableUndoRegistration()
        if let album = step.album {
            sidebar.reload()
            DispatchQueue.main.async { [weak self] in self?.sidebar.beginRenaming(album) }
        }
        revealSoon(ids)
    }

    private func undoCopies(_ step: CopyStep) {
        let undo = library.undoManager
        // Redo copies the same photos again, those still in the library.
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                let originals = step.originals.filter(controller.library.snapshot.inLibrary)
                controller.makeCopies(of: originals, into: step.target, besideOriginals: step.besideOriginals, actionName: step.actionName)
            }
        }
        step.isUndone = true
        // Still being made: they're deleted once they are.
        guard let copies = step.copies else { return }
        let ids = copies.map(\.copy)
        // Out of where they went first, in case macOS is told not to delete them.
        undo.disableUndoRegistration()
        switch step.target {
        case let .album(id): library.removeFromAlbum(ids, album: id)
        case .newAlbum: if let album = step.album { library.deleteAlbum(album) }
        case .library, .favorites, .label: break
        }
        undo.enableUndoRegistration()
        library.deletePhotos(ids)
    }
}
