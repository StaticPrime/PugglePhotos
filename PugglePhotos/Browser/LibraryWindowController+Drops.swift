import AppKit
import PugglePhotosKit

/// One drop of files from another app, kept to undo and redo it as one step.
final class FileDropStep {
    let files: [ImportFile]
    /// Photos already in the library that were dropped again: they go where the files went, without a second copy.
    let existing: [PhotoID]
    let target: FileDropTarget
    /// What the files became, once added (nil until then).
    var added: [PhotoID]?
    /// The photos already in the library that joined where they were dropped (not ones that were there already), so
    /// Undo lets go of only those.
    var joined: [PhotoID] = []
    /// The album a drop on Albums made.
    var album: UUID?
    var isUndone = false

    init(files: [ImportFile], existing: [PhotoID], target: FileDropTarget) {
        self.files = files
        self.existing = existing
        self.target = target
    }
}

// MARK: Dropping files from other apps

extension LibraryWindowController {
    /// Where files dropped at a point in the middle go: into what it shows. Nil where nothing can be dropped (on
    /// Memories, the Journal or a memory, or before the library is there).
    func fileDropTarget(at point: NSPoint) -> FileDropTarget? {
        guard library.access == .authorized, library.hasLoaded else { return nil }
        switch state.source {
        case .library, .videos, .recentlyAdded: return .library
        case .favorites: return .favorites
        case let .album(id): return .album(id)
        case let .label(id): return .label(id)
        case .allAlbums:
            // On a cover, into that album; anywhere else, into a new one.
            return albums.album(atWindowPoint: dropZone.convert(point, to: nil)).map { .album($0) } ?? .newAlbum
        case .memories, .memory, .journal, .map, .sharedAlbum: return nil
        }
    }

    /// What the middle says while files are dragged over it.
    func dropTitle(_ target: FileDropTarget) -> String {
        switch target {
        case .library: "Add to Library"
        case .favorites: "Add to Favorites"
        case let .album(id): "Add to “\(library.catalog.album(id)?.title ?? "Album")”"
        case let .label(id): "Add with the Label “\(library.catalog.label(id)?.displayName ?? "Label")”"
        case .newAlbum: "Add to a New Album"
        }
    }

    func sidebarDropFiles(_ urls: [URL], on target: FileDropTarget) { dropFiles(urls, on: target) }

    /// Photos and videos dropped from other apps, on the middle or the sidebar: reads them (folders all the way
    /// down), asks about any already in the library, then adds them where they were dropped.
    func dropFiles(_ urls: [URL], on target: FileDropTarget) {
        guard !urls.isEmpty else { return }
        addingStatus = "Adding…"
        Task {
            let dropped = await FileImport.read(urls)
            addingStatus = nil
            addDropped(dropped, on: target)
        }
    }

    func addDropped(_ dropped: DroppedFiles, on target: FileDropTarget) {
        let files = dropped.files
        guard !files.isEmpty else {
            reportUnreadable(dropped.unreadable)
            return
        }
        let already = library.alreadyAdded(files)
        guard !already.isEmpty else {
            addFiles(files, existing: [], on: target, unreadable: dropped.unreadable)
            return
        }
        askAboutCopies(of: files, already: already, target: target) { [weak self] addAgain in
            guard let self, let addAgain else { return }
            if addAgain {
                addFiles(files, existing: [], on: target, unreadable: dropped.unreadable)
            } else {
                addFiles(files.filter { already[$0.url] == nil }, existing: files.compactMap { already[$0.url] }, on: target,
                         unreadable: dropped.unreadable)
            }
        }
    }

    /// Some of the files dropped look like photos already in the library: add them again, or skip them (they still
    /// go where they were dropped)? Nil cancels the whole drop.
    private func askAboutCopies(of files: [ImportFile], already: [URL: PhotoID], target: FileDropTarget, answer: @escaping (Bool?) -> Void) {
        guard let window else {
            answer(false)
            return
        }
        let copies = files.filter { already[$0.url] != nil }
        let alert = NSAlert()
        if copies.count == 1 {
            alert.messageText = "“\(copies[0].name)” is already in your library."
        } else if copies.count == files.count {
            alert.messageText = "These \(library.formatting.number(files.count)) \(FileImport.plural(files)) are already in your library."
        } else {
            alert.messageText = "\(library.formatting.number(copies.count)) of these \(FileImport.plural(files)) are already in your library."
        }
        var message = copies.count == 1 ? "Add it again, or skip it?" : "Add them again, or skip them?"
        if let place = placeName(target) {
            message += copies.count == 1 ? " Skipped, it still goes into \(place)." : " Skipped, they still go into \(place)."
        }
        alert.informativeText = message
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Add Again")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: answer(false)
            case .alertSecondButtonReturn: answer(true)
            default: answer(nil)
            }
        }
    }

    /// Where a drop puts photos besides the library, in a sentence; nil for just the library.
    private func placeName(_ target: FileDropTarget) -> String? {
        switch target {
        case .library: nil
        case .favorites: "Favorites"
        case let .album(id): "“\(library.catalog.album(id)?.title ?? "the album")”"
        case let .label(id): "the label “\(library.catalog.label(id)?.displayName ?? "")”"
        case .newAlbum: "the new album"
        }
    }

    private func reportUnreadable(_ names: [String]) {
        guard let first = names.first else { return }
        if names.count == 1 {
            showProblem("“\(first)” couldn’t be read.", "It may be damaged, or still being copied.")
        } else {
            let listed = names.prefix(4).map { "“\($0)”" }.joined(separator: ", ") + (names.count > 4 ? " and others" : "")
            showProblem("\(library.formatting.number(names.count)) files couldn’t be read.", "\(listed). They may be damaged, or still being copied.")
        }
    }

    /// One drop: adds the files, then puts them (and photos already in the library that were dropped again) where
    /// they were dropped. One step to undo, which takes out what was added and lets go of the rest; Redo does the
    /// drop again.
    func addFiles(_ files: [ImportFile], existing: [PhotoID], on target: FileDropTarget, unreadable: [String] = []) {
        let step = FileDropStep(files: files, existing: existing, target: target)
        step.joined = joining(existing, target)
        // Only photos already here, and already where they were dropped: nothing to do but show them.
        if files.isEmpty, step.joined.isEmpty {
            revealSoon(existing)
            reportUnreadable(unreadable)
            return
        }
        let undo = library.undoManager
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.undoDrop(step) }
        }
        undo.setActionName(Self.dropActionName(step))
        guard !files.isEmpty else {
            step.added = []
            placeDropped(step)
            reportUnreadable(unreadable)
            return
        }
        addingStatus = "Adding " + (files.count == 1 ? (files[0].kind.isVideo ? "a video" : "a photo")
            : "\(library.formatting.number(files.count)) \(FileImport.plural(files))") + "…"
        let total = files.count
        library.addFiles(files, progress: { [weak self] done in
            guard let self, done < total else { return }
            addingStatus = "Adding \(library.formatting.number(done)) of \(library.formatting.number(total))…"
        }) { [weak self] added in
            guard let self else { return }
            addingStatus = nil
            step.added = added
            reportUnreadable(unreadable)
            // Undone while it was being added: what was added comes out again.
            if step.isUndone {
                library.deleteAdded(added)
                return
            }
            placeDropped(step)
        }
    }

    /// "Add 3 Photos", or for photos only already in the library, what dropping them on that place does.
    static func dropActionName(_ step: FileDropStep) -> String {
        if !step.files.isEmpty { return "Add " + FileImport.countTitle(step.files) }
        switch step.target {
        case .library: return "Add Photos"
        case .favorites: return "Favorite"
        case .album: return "Add to Album"
        case .label: return "Add Label"
        case .newAlbum: return "New Album"
        }
    }

    /// The photos already in the library that dropping them would add somewhere they aren't yet.
    private func joining(_ existing: [PhotoID], _ target: FileDropTarget) -> [PhotoID] {
        switch target {
        case .library:
            return []
        case .newAlbum:
            return existing
        case .favorites:
            return existing.filter { library.snapshot.item($0)?.isFavorite == false }
        case let .album(id):
            let inAlbum = Set(library.catalog.album(id)?.items ?? [])
            return existing.filter { !inAlbum.contains($0) }
        case let .label(id):
            let labeled = library.membership.photos(labeled: id)
            return existing.filter { !labeled.contains($0) }
        }
    }

    /// Puts what a drop added (and what was there already) where it was dropped, as part of the drop's own undo
    /// step, then shows them.
    private func placeDropped(_ step: FileDropStep) {
        let ids = (step.added ?? []) + step.existing
        guard !ids.isEmpty else { return }
        let undo = library.undoManager
        undo.disableUndoRegistration()
        switch step.target {
        case .library: break
        case .favorites: library.setFavorite(ids, true)
        case let .album(id): library.addToAlbum(ids, album: id)
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

    private func undoDrop(_ step: FileDropStep) {
        let undo = library.undoManager
        // Redo drops the same files again. A file still in the library (if taking it out was refused) isn't added a
        // second time.
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                let present = controller.library.alreadyAdded(step.files)
                controller.addFiles(step.files.filter { present[$0.url] == nil },
                                    existing: step.existing + step.files.compactMap { present[$0.url] }, on: step.target)
            }
        }
        step.isUndone = true
        // Still being added: it comes out once it's in.
        guard let added = step.added else { return }
        let all = added + step.joined
        undo.disableUndoRegistration()
        switch step.target {
        case .library: break
        case .favorites: library.setFavorite(all, false)
        case let .album(id): library.removeFromAlbum(all, album: id)
        case let .label(id): library.edit("Remove Label") { $0.setLabel(id, on: all, false) }
        case .newAlbum: if let album = step.album { library.deleteAlbum(album) }
        }
        undo.enableUndoRegistration()
        library.deleteAdded(added)
    }

    // MARK: Showing what was dropped

    /// Selects photos and scrolls to them once the middle shows them, which may take a moment or two while the
    /// library and the catalog catch up.
    func revealSoon(_ ids: [PhotoID]) {
        pendingReveal = (ids, 0)
        revealPending()
    }

    func revealPending() {
        guard let pending = pendingReveal else { return }
        let shown = Set(content.allIDs)
        let present = pending.ids.filter(shown.contains)
        if !present.isEmpty {
            pendingReveal = nil
            reveal(present)
        } else {
            pendingReveal = pending.tries >= 3 ? nil : (pending.ids, pending.tries + 1)
        }
    }
}
