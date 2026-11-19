import AppKit
import PugglePhotosKit
import SwiftUI

/// Sharing albums: the sheet for sharing one of yours and seeing who it's shared with, and leaving one shared with you.
extension LibraryWindowController {
    /// The sharing sheet for an album of yours, or, with no album, for a new one to share holding the photos selected.
    func presentShareSheet(album: UUID?) {
        let model = ShareAlbumModel(sharing: sharing, library: library, albumID: album)
        let selection = state.selection.filter(library.snapshot.inLibrary)
        model.makeAlbum = { [weak self] name in
            guard let self else { return nil }
            let id = library.newAlbum(title: name, items: selection)
            go(to: .album(id))
            return id
        }
        model.pendingItems = selection
        model.loadSize()
        if let album, let value = library.catalog.album(album), let cover = library.arranger.cover(of: value) {
            _ = library.thumbnails.request(cover, pixels: 240) { [weak model] image in model?.cover = image }
        }
        presentSheet { dismiss in
            model.done = dismiss
            return ShareAlbumView(model: model)
        }
        shareSheet = model
    }

    /// Leaves an album shared with you, once the person says so.
    func leaveSharedAlbum(_ id: UUID) {
        guard let window, let album = sharing.sharedWithMe(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Leave “\(album.title)”?"
        alert.informativeText = "It goes from this Mac, photos and all. \(album.owner.name) can share it with you again."
        alert.addButton(withTitle: "Leave")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.sharing.leave(id) { error in
                    if let error { self?.showProblem("You couldn’t leave “\(album.title)”.", error.localizedDescription) }
                }
            }
        }
    }
}
