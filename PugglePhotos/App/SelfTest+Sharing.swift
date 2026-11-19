#if DEBUG
import AppKit
import PugglePhotosKit

extension SelfTest {
    /// Shared albums, on the stand-in for iCloud: one shared with you arriving, its photos staying out of your library,
    /// to look at in the gallery and as a book, growing, and left; and one of yours shared, joined, kept up to date as
    /// it changes, and stopped.
    static func sharingSteps(_ app: AppDelegate, window: LibraryWindowController) {
        let library = app.library!
        let sharing = app.sharing!
        guard let standIn = sharing.backend as? StandInSharing, let notices = app.notifications as? RecordingNotificationCenter else {
            step { check(false, "sharing runs on the stand-in for iCloud") }
            return
        }
        /// Whether a command can be chosen for what's showing.
        func allowed(_ action: Selector) -> Bool {
            window.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        func sidebarSources() -> [LibrarySource] {
            (0..<window.sidebar.outlineView.numberOfRows).compactMap { (window.sidebar.outlineView.item(atRow: $0) as? SidebarNode)?.source }
        }
        /// Commands that change photos, which a photo of your own has and one shared with you doesn't.
        let changes = [#selector(LibraryWindowController.phToggleFavorite(_:)), #selector(LibraryWindowController.phChangeDate(_:)),
                       #selector(LibraryWindowController.phAddToAlbum(_:)), #selector(LibraryWindowController.phToggleLabel(_:)),
                       #selector(LibraryWindowController.phWriteNote(_:)), #selector(LibraryWindowController.phNewAlbumWithSelection(_:))]
        var libraryCount = 0
        var dayCounts: [CivilDay: Int] = [:]
        var garden: SharedAlbum? { sharing.sharedWithMe(StandInSharing.gardenID) }

        // MARK: Shared with you
        step {
            check(!CloudKitSharing.isEntitled, "a copy not signed for iCloud is told so, and never reaches for it")
            libraryCount = library.snapshot.count
            dayCounts = library.snapshot.countsByDay()
            window.go(to: .library)
            standIn.granShares(photos: 6)
            wait(upTo: 8) { garden?.items.count == 6 }
        }
        step {
            check(garden.map { $0.title == "Gran’s Garden" && !$0.isMine && $0.owner.name == "Gran" } == true,
                  "an album shared with you arrives", "\(sharing.sharedWithMe.map(\.title))")
            let pictures = garden?.items.map { sharing.store.pictureURL(album: StandInSharing.gardenID, item: $0) } ?? []
            check(!pictures.isEmpty && pictures.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                  "its pictures are kept on this Mac")
            check(notices.sharedNotices.last.map { $0.title == "Gran shared “Gran’s Garden” with you" && $0.body.hasPrefix("6 photos") } == true,
                  "a notification says it's been shared with you", "\(notices.sharedNotices.map(\.title))")
            check(library.snapshot.count == libraryCount && library.snapshot.countsByDay() == dayCounts
                  && !library.snapshot.allIDs.contains(where: SharedAlbum.isShared), "its photos stay out of your library and its days")
            check(sidebarSources().contains(.sharedAlbum(StandInSharing.gardenID)), "it's listed under Shared Albums")
            // What a photo of your own can have done to it, for what follows to be measured against.
            window.setSelection(Array(library.snapshot.allIDs.prefix(1)))
            let grid = window.grid
            check(changes.allSatisfy(allowed) && grid.collectionView(grid.collectionView, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) != nil,
                  "a photo of your own can be changed and dragged")
            window.setSelection([])
            window.go(to: .sharedAlbum(StandInSharing.gardenID))
        }
        step {
            let ids = garden?.photoIDs ?? []
            check(window.content.allIDs == ids && !ids.isEmpty, "it shows its photos, in their owner's order")
            check(window.window?.subtitle.hasPrefix("Shared by Gran") == true, "the window says who shared it", window.window?.subtitle ?? "")
            check(library.details(ids[0]).caption == "The first roses" && library.details(ids[0]).note == "Grandpa planted these in 1987.",
                  "captions and notes are its owner's")
            window.setSelection([ids[0]])
            check(changes.allSatisfy { !allowed($0) } && allowed(#selector(LibraryWindowController.phShowBook(_:))),
                  "nothing about its photos can be changed, but it opens as a book")
            let grid = window.grid
            check(grid.collectionView(grid.collectionView, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) == nil,
                  "its photos can't be dragged into your albums")
            var catalog = library.catalog
            if let album = catalog.albums.first?.id { _ = catalog.add([ids[0]], toAlbum: album) }
            check(catalog.albums.first.map { !$0.items.contains(ids[0]) } == true, "nor put in one some other way")
            window.setSelection([])
            window.setViewMode(.book)
        }
        step {
            let book = window.book
            check(window.isShowingBook && book.isReadOnly && book.layout.pages.count >= 6, "it opens as a book, to look through")
            check(book.layout.settings.paper == .linen && book.layout.settings.cover == .sage, "made as its owner made it")
            check(book.controls.sharedBy == "Gran", "the bar says whose it is and offers nothing to change")
            // A click on a photo picks nothing up: the page turns.
            book.bookView.go(to: 2, animated: false)
            if let page = book.layout.state(2).right, let placement = book.layout.pages[page].placements.first {
                let point = book.bookView.viewPoint(placement.center, onLeft: false)
                bookMouse(.leftMouseDown, at: point, in: book.bookView)
                bookMouse(.leftMouseUp, at: point, in: book.bookView)
            }
            check(book.bookView.selected == nil, "a photo in it can't be picked up")
            window.setViewMode(.gallery)
            standIn.granShares(photos: 2)
            wait(upTo: 8) { garden?.items.count == 8 }
        }
        step {
            check(window.content.allIDs.count == 8, "when its owner adds photos, they show")
            check(notices.sharedNotices.last.map { $0.title == "Gran added to “Gran’s Garden”" && $0.body == "2 photos added. Click to see them." } == true,
                  "and a notification says so", "\(notices.sharedNotices.last?.body ?? "none")")
        }

        // MARK: Yours, shared
        var summer: UUID?
        var sheet: ShareAlbumModel?
        step {
            summer = library.catalog.albums.first { $0.title == "Summer at the Lake" }?.id
            guard let summer else { return }
            window.go(to: .album(summer))
            window.presentShareSheet(album: summer)
            sheet = window.shareSheet
            check(sheet?.title == "Summer at the Lake" && sheet?.shared == nil, "Share Album opens the sharing sheet for the album")
            sheet?.share()
            wait(upTo: 20) { sharing.mine(summer)?.url != nil }
        }
        step {
            guard let summer, let shared = sharing.mine(summer), let album = library.catalog.album(summer) else {
                check(false, "sharing sends the album")
                return
            }
            let photos = album.items.filter(library.snapshot.inLibrary)
            check(shared.items.count == photos.count && shared.items.map(\.source) == photos, "sharing sends the album, every photo")
            check(standIn.sentPictures[summer]?.count == photos.count
                  && Set(photos).isSubset(of: Set((library.baseSource as? SamplePhotoSource)?.exported ?? [])),
                  "each photo's own file goes with it, at full size")
            check(shared.book?.handwriting == Handwriting.family, "its book is written in your hand, wherever it's opened")
            check(sidebarSources().contains(.album(summer)) && sheet?.shared != nil, "it's listed under Shared Albums, and the sheet shows who's in it")
            sheet?.address = "sam@example.com"
            sheet?.invite()
            wait(upTo: 4) { sharing.mine(summer)?.participants.contains { $0.address == "sam@example.com" && $0.status == .joined } == true }
        }
        var publishes = 0
        var edited: PhotoID?
        /// Whether the edited photo has gone out with its new caption and note.
        func sent(_ summer: UUID) -> Bool {
            standIn.shared[summer]?.items.contains { $0.source == edited && $0.caption == "Sunny day" && $0.note == "Lake was warm." } == true
        }
        step {
            guard let summer else { return }
            check(sharing.mine(summer)?.participants.contains { $0.address == "sam@example.com" && $0.status == .joined } == true,
                  "someone invited joins")
            sheet?.copyLink()
            check(NSPasteboard.general.string(forType: .string) == sharing.mine(summer)?.url?.absoluteString, "Copy Link copies its link")
            publishes = standIn.publishes
            edited = library.catalog.album(summer)?.items.first
            guard let edited else { return }
            library.edit("Caption") { $0.setCaption("Sunny day", for: [edited]) }
            library.edit("Note") { $0.setNote("Lake was warm.", for: edited) }
            wait(upTo: 5) { sent(summer) }
        }
        step {
            guard let summer else { return }
            check(sent(summer), "a change to a shared album reaches everyone it's shared with")
            check(standIn.publishes == publishes + 1, "a run of changes goes as one", "\(standIn.publishes - publishes) sends")
            sheet?.stopSharing()
            wait(upTo: 3) { sharing.mine(summer) == nil }
        }
        step {
            guard let summer else { return }
            check(sharing.mine(summer) == nil && library.catalog.album(summer) != nil && standIn.shared[summer] == nil,
                  "Stop Sharing takes it back from everyone; the album stays yours")
            sheet?.done?()
            window.go(to: .sharedAlbum(StandInSharing.gardenID))
            sharing.leave(StandInSharing.gardenID) { _ in }
            wait(upTo: 3) { garden == nil }
        }
        step {
            check(garden == nil && library.snapshot.extras.isEmpty
                  && !FileManager.default.fileExists(atPath: sharing.store.picturesFolder.appendingPathComponent(StandInSharing.gardenID.uuidString).path),
                  "leaving an album shared with you takes it away, pictures and all")
            check(window.state.source == .library && !sidebarSources().contains(.sharedAlbum(StandInSharing.gardenID)),
                  "and the window goes back to the library")
        }
    }
}
#endif
