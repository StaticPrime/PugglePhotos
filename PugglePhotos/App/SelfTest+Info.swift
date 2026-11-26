#if DEBUG
import AppKit
import PugglePhotosKit

extension SelfTest {
    /// Get Info: offered on a photo's right-click menu (and the viewer's, never a book's), opening a window of its own
    /// with what the file says and where it was taken, named; writing its caption and note, making it a favorite,
    /// adjusting when it was taken and setting, moving and removing where, each in the library, with undo; keeping up
    /// with changes made elsewhere; and a photo shared with you looked at, not changed.
    static func infoSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        let sharing = app.sharing!
        func allowed(_ action: Selector) -> Bool { window.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
        let getInfo = #selector(LibraryWindowController.phGetInfo(_:))
        var photo: PhotoID?
        var info: InfoModel?
        var taken = Date()
        var falls: FoundPlace?
        let clicked = GeoPoint(latitude: 45.5005, longitude: -122.6010)

        step {
            InfoWindowController.keepsShowingBehind = true
            window.go(to: .library)
            photo = library.snapshot.items.first { $0.location != nil && $0.kind == .photo && !$0.isFavorite }?.id
            guard let photo else { return }
            window.setSelection([photo])
            check(window.photoMenu(for: [photo]).items.contains { $0.action == getInfo } && allowed(getInfo), "a photo's right-click menu offers Get Info")
            window.phGetInfo(nil)
            info = window.infoWindows[photo]?.model
            wait(upTo: 5) { info?.readingFile == false && info?.placeName != nil }
        }
        step {
            guard let photo, let info else {
                check(false, "Get Info opens a window for the photo")
                return
            }
            let panel = window.infoWindows[photo]?.window
            check(panel?.isVisible == true && panel?.title == "Info" && panel !== window.window, "Get Info opens a window of its own for the photo")
            let metadata = info.metadata
            check(metadata?.camera == "Puggle Pocket 3" && metadata?.settings.count == 5 && metadata?.format == "HEIC" && (metadata?.fileSize ?? 0) > 0,
                  "it says what the file says: the camera, how it was set, its size and format", "\(String(describing: metadata))")
            check(info.placeName?.isEmpty == false, "and names where it was taken", info.placeName ?? "no name")
            window.phGetInfo(nil)
            check(window.infoWindows.count == 1, "Get Info again brings the same window forward")
            info.caption = "Tide pools"
            info.typed("caption")
            info.saveCaption()
            info.note = "Found a starfish."
            info.typed("note")
            info.saveNote()
            check(library.details(photo).caption == "Tide pools" && library.details(photo).note == "Found a starfish.", "its caption and note are written there")
            info.toggleFavorite()
            wait(upTo: 3) { library.snapshot.item(photo)?.isFavorite == true }
        }
        step {
            guard let photo, let info, let item = library.snapshot.item(photo) else { return }
            check(item.isFavorite && info.item?.isFavorite == true, "it's made a favorite there")
            taken = item.date
            info.startAdjustingDate()
            info.pendingDate = taken.addingTimeInterval(-3 * 86_400 - 3_600)
            info.adjustDate()
            wait(upTo: 3) { library.snapshot.item(photo)?.date == taken.addingTimeInterval(-3 * 86_400 - 3_600) }
        }
        step {
            guard let photo else { return }
            check(library.snapshot.item(photo)?.date == taken.addingTimeInterval(-3 * 86_400 - 3_600) && !(info?.adjustingDate ?? true),
                  "Adjust changes when it was taken, in the library")
            library.undoManager.undo()
            wait(upTo: 3) { library.snapshot.item(photo)?.date == taken }
        }
        step {
            guard let photo, let info else { return }
            check(library.snapshot.item(photo)?.date == taken, "and Undo puts it back")
            info.startChoosingPlace()
            info.searchText = "falls"
            info.search()
            wait(upTo: 3) { info.results.contains { $0.name == "Multnomah Falls" } }
        }
        step {
            guard let photo, let info else { return }
            falls = info.results.first { $0.name == "Multnomah Falls" }
            check(falls != nil, "searching finds a place by its name", "\(info.results.map(\.name))")
            guard let falls else { return }
            info.setPlace(falls.place)
            wait(upTo: 3) { library.snapshot.item(photo)?.location == falls.place && info.placeName?.hasPrefix("Multnomah Falls") == true }
        }
        step {
            guard let photo, let info, let falls else { return }
            check(library.snapshot.item(photo)?.location == falls.place && !info.choosingPlace, "choosing it sets where the photo was taken, in the library")
            check(info.placeName?.hasPrefix("Multnomah Falls") == true, "and the window names it", info.placeName ?? "")
            // A click on the map puts the pin there, to set.
            info.startChoosingPlace()
            info.pendingPlace = clicked
            info.setPlace(info.pendingPlace)
            wait(upTo: 3) { library.snapshot.item(photo)?.location == clicked }
        }
        step {
            guard let photo, let info else { return }
            check(library.snapshot.item(photo)?.location == clicked, "a place clicked on the map is set")
            info.setPlace(nil)
            wait(upTo: 3) { library.snapshot.item(photo)?.location == nil && !library.arranger.ids(for: .map).contains(photo) && info.placeName == nil }
        }
        step {
            guard let photo, let info else { return }
            check(library.snapshot.item(photo)?.location == nil && !library.arranger.ids(for: .map).contains(photo) && info.placeName == nil,
                  "Remove Place takes it off the map")
            library.undoManager.undo()
            // The map's list catches up a moment after the photo itself.
            wait(upTo: 3) { library.snapshot.item(photo)?.location == clicked && library.arranger.ids(for: .map).contains(photo) }
        }
        step {
            guard let photo, let info else { return }
            check(library.snapshot.item(photo)?.location == clicked && library.arranger.ids(for: .map).contains(photo), "and Undo puts it back")
            // Changed elsewhere, it changes in the window too.
            library.setFavorite([photo], false)
            library.edit("Caption") { $0.setCaption("Rock pools", for: [photo]) }
            wait(upTo: 3) { info.item?.isFavorite == false && info.caption == "Rock pools" }
        }
        step {
            guard let photo, let info else { return }
            check(info.item?.isFavorite == false && info.caption == "Rock pools", "the window keeps up with changes made elsewhere",
                  "favorite \(info.item?.isFavorite == true), caption “\(info.caption)”, library’s “\(library.details(photo).caption)”")
            // The viewer offers it too; a book doesn't.
            window.openViewer(photo)
            check(window.viewerMenu(for: photo)?.items.contains { $0.action == getInfo } == true && allowed(getInfo), "the viewer's right-click menu offers Get Info")
            window.closeViewer()
            if let album = library.catalog.albums.first(where: { !$0.items.isEmpty })?.id {
                window.go(to: .album(album))
                window.setViewMode(.book)
            }
            wait(upTo: 3) { window.isShowingBook }
        }
        step {
            check(window.isShowingBook && !allowed(getInfo), "a book doesn't")
            window.setViewMode(.gallery)
            window.infoWindows.values.forEach { $0.close() }
            check(window.infoWindows.isEmpty, "a closed Info window is let go")
            // A photo shared with you, to look at.
            (sharing.backend as? StandInSharing)?.granShares(photos: 2)
            wait(upTo: 8) { sharing.sharedWithMe(StandInSharing.gardenID) != nil }
        }
        step {
            guard let id = sharing.sharedWithMe(StandInSharing.gardenID)?.photoIDs.first else {
                check(false, "a photo shared with you opens in Info")
                return
            }
            window.showInfo(for: [id])
            let shared = window.infoWindows[id]?.model
            shared?.toggleFavorite()
            shared?.setPlace(clicked)
            check(shared?.canChange == false && library.snapshot.item(id)?.isFavorite == false && library.snapshot.item(id)?.location == nil,
                  "a photo shared with you opens in Info to look at, not change")
            window.infoWindows.values.forEach { $0.close() }
            sharing.leave(StandInSharing.gardenID) { _ in }
            wait(upTo: 3) { sharing.sharedWithMe(StandInSharing.gardenID) == nil }
        }
        step {
            InfoWindowController.keepsShowingBehind = false
            window.go(to: .library)
        }
    }
}
#endif
