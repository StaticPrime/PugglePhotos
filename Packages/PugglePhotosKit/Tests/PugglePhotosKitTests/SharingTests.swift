import CoreGraphics
import Foundation
import Testing
@testable import PugglePhotosKit

@Suite struct SharingTests {
    let owner = ShareParticipant(id: "owner", name: "Jamie Rivera", isOwner: true)

    func media(_ count: Int) -> [MediaItem] {
        (0..<count).map { index in
            MediaItem(id: PhotoID("library-\(index)"), kind: index == 5 ? .video : (index == 2 ? .livePhoto : .photo),
                      date: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index) * 3_600.25),
                      pixelWidth: index % 3 == 0 ? 3024 : 4032, pixelHeight: index % 3 == 0 ? 4032 : 3024,
                      duration: index == 5 ? 12 : 0, fileName: "IMG_\(index).HEIC")
        }
    }

    /// An album of seven photos with captions, a note, and a book that's been worked on: a photo moved to another page
    /// and turned, its sticky note dragged, one left out, writing beside one and on the title page, and a page added.
    func workedAlbum() -> (album: Album, items: [MediaItem], catalog: Catalog) {
        let items = media(7)
        var catalog = Catalog()
        let id = catalog.addAlbum(title: "Lake Days", items: items.map(\.id))
        catalog.setAlbumNote(id, to: "Every July we go back.")
        catalog.setCaption("First swim", for: ["library-0"])
        catalog.setCaption("The dock", for: ["library-3"])
        catalog.setNote("She jumped first.", for: "library-0")
        var book = BookSettings(frame: .instant, perPage: .two, notes: .sticky, binding: .threeRing)
        book.changeOverride("library-4") { $0.page = .photo("library-0"); $0.angle = 12 }
        book.changeOverride("library-0") { $0.sticky = BookSticky(center: CGPoint(x: 10, y: -20), size: CGSize(width: 90, height: 90), angle: 4) }
        book.hidden = ["library-6"]
        book.writings = [BookWriting(text: "Best summer", spot: .photo("library-3"), center: CGPoint(x: 300, y: 700)),
                         BookWriting(text: "For Gran", spot: .title, center: CGPoint(x: 300, y: 720))]
        book.extraPages = [BookExtraPage(after: .photo("library-1"))]
        catalog.setBook(book, for: id)
        return (catalog.album(id)!, items, catalog)
    }

    @Test func sharedPhotosAreNamedApartFromTheLibrary() {
        let album = UUID(), item = UUID()
        let id = SharedAlbum.photoID(album: album, item: item)
        #expect(SharedAlbum.isShared(id) && !SharedAlbum.isShared("library-0"))
        #expect(SharedAlbum.parse(id).map { $0.album == album && $0.item == item } == true)
        #expect(SharedAlbum.parse("shared:nonsense") == nil && SharedAlbum.parse("library-0") == nil)
    }

    @Test func aSharedBookIsTheOwnersBook() throws {
        let (album, items, catalog) = workedAlbum()
        let shared = SharedAlbum.sharing(album, items: items, catalog: catalog, cover: "library-1", owner: owner, previous: nil)
        #expect(shared.items.map(\.source) == items.map(\.id) && shared.isMine && shared.title == "Lake Days" && shared.story == "Every July we go back.")
        #expect(shared.items[0].caption == "First swim" && shared.items[0].note == "She jumped first." && shared.items[1].caption.isEmpty)
        #expect(shared.coverID == shared.photoID(of: shared.items[1]))
        #expect(shared.mediaItems[2].kind == .photo && shared.mediaItems[5].kind == .video, "a live photo goes as its picture")

        // The owner's book and the book as it's shared lay out alike, photo for photo.
        let mine = BookLayout(items: items.map { BookItem(id: $0.id, aspect: $0.aspectRatio, isVideo: $0.kind.isVideo) },
                              captions: ["library-0": "First swim", "library-3": "The dock"], notes: ["library-0": "She jumped first."],
                              settings: catalog.book(album.id), coverPhoto: "library-1")
        let theirs = BookLayout(items: shared.bookItems, captions: shared.captions, notes: shared.notes,
                                settings: try #require(shared.book), coverPhoto: shared.coverID)
        let name = Dictionary(uniqueKeysWithValues: shared.items.map { ($0.source!, shared.photoID(of: $0)) })
        #expect(mine.pages.count == theirs.pages.count)
        for (page, (a, b)) in zip(mine.pages, theirs.pages).enumerated() {
            #expect(a.kind == b.kind && a.number == b.number, "page \(page)")
            #expect(a.placements.map { name[$0.id] } == b.placements.map(\.id), "page \(page) holds the same photos")
            for (x, y) in zip(a.placements, b.placements) {
                #expect(x.center == y.center && x.angle == y.angle && x.imageSize == y.imageSize && x.sticky == y.sticky
                        && x.caption == y.caption && x.note == y.note && x.noteStyle == y.noteStyle, "\(x.id) lies as it does in the owner's book")
            }
            #expect(a.writings.map(\.text) == b.writings.map(\.text), "page \(page) has the same writing")
        }
        #expect(mine.pages.flatMap(\.placements).contains { $0.id == "library-4" && $0.angle == 12 }, "the moved photo is turned")
        #expect(!theirs.pages.flatMap(\.placements).contains { $0.id == name["library-6"] }, "the photo left out stays out")
    }

    @Test func sharingAgainKeepsWhatWasShared() {
        var (album, items, catalog) = workedAlbum()
        let first = SharedAlbum.sharing(album, items: items, catalog: catalog, cover: nil, owner: owner, previous: nil,
                                        now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        var withLink = first
        withLink.url = URL(string: "https://example.com/share/1")
        withLink.participants.append(ShareParticipant(id: "gran", name: "Gran", address: "gran@example.com", status: .invited))
        let again = SharedAlbum.sharing(album, items: items, catalog: catalog, cover: nil, owner: owner, previous: withLink,
                                        now: Date(timeIntervalSinceReferenceDate: 900_000_000))
        #expect(again == withLink, "nothing changed, so nothing changes, not even when it last did")

        // A photo taken out and one added: those shared before keep their names.
        album.items.removeAll { $0 == "library-1" }
        let added = MediaItem(id: "library-9", date: Date(timeIntervalSinceReferenceDate: 700_100_000))
        items = items.filter { $0.id != "library-1" } + [added]
        catalog.setCaption("Sunset", for: ["library-9"])
        let changed = SharedAlbum.sharing(album, items: items, catalog: catalog, cover: nil, owner: owner, previous: withLink,
                                          now: Date(timeIntervalSinceReferenceDate: 900_000_000))
        let before = Dictionary(uniqueKeysWithValues: first.items.map { ($0.source!, $0.id) })
        #expect(changed.items.dropLast().allSatisfy { before[$0.source!] == $0.id })
        #expect(changed.items.last.map { $0.caption == "Sunset" && before[$0.source!] == nil } == true)
        #expect(changed.modified == Date(timeIntervalSinceReferenceDate: 900_000_000) && changed.url == withLink.url
                && changed.participants == withLink.participants)
        #expect(!changed.sameContent(as: withLink))
    }

    @Test func aSharedBookIsInTheOwnersHand() {
        let (album, items, catalog) = workedAlbum()
        let shared = SharedAlbum.sharing(album, items: items, catalog: catalog, cover: nil, owner: owner, handwriting: "Noteworthy", previous: nil)
        #expect(shared.book?.handwriting == "Noteworthy", "written as its owner sees it")
        var chosen = album
        chosen.book?.handwriting = "Marker Felt"
        #expect(SharedAlbum.sharing(chosen, items: items, catalog: catalog, cover: nil, owner: owner, handwriting: "Noteworthy",
                                    previous: nil).book?.handwriting == "Marker Felt", "a hand chosen for the book stays")
        let plain = Album(title: "Plain", items: items.map(\.id))
        #expect(SharedAlbum.sharing(plain, items: items, catalog: catalog, cover: nil, owner: owner, handwriting: "Noteworthy",
                                    previous: nil).book?.handwriting == "Noteworthy", "even a book as it first comes")
    }

    @Test func renamingLeavesOutWhatsGone() {
        var book = BookSettings()
        book.changeOverride("a") { $0.angle = 5; $0.page = .photo("gone") }
        book.changeOverride("gone") { $0.angle = 9 }
        book.hidden = ["a", "gone"]
        book.writings = [BookWriting(text: "by a", spot: .photo("a"), center: .zero),
                         BookWriting(text: "by gone", spot: .photo("gone"), center: .zero),
                         BookWriting(text: "on the back", spot: .back, center: .zero)]
        book.extraPages = [BookExtraPage(after: .photo("gone")), BookExtraPage(after: .photo("a"))]
        let renamed = book.renamingPhotos { $0 == "a" ? "A" : nil }
        #expect(renamed.overrides.keys.sorted() == ["A"] && renamed.overrides["A"]?.angle == 5 && renamed.overrides["A"]?.page == nil)
        #expect(renamed.hidden == ["A"])
        #expect(renamed.writings.map(\.text) == ["by a", "on the back"] && renamed.writings[0].spot == .photo("A"))
        #expect(renamed.extraPages.map(\.after) == [.photo("gone"), .photo("A")])
    }

    @Test func photosSharedWithYouAreOnlyLookedUp() {
        let library = media(3)
        let shared = SharedAlbum(id: UUID(), title: "Gran's Garden", created: Date(), modified: Date(),
                                 items: [SharedItem(kind: .photo, date: library[1].date, pixelWidth: 4000, pixelHeight: 3000, layoutSeed: 1),
                                         SharedItem(kind: .video, date: Date(timeIntervalSinceReferenceDate: 600_000_000), pixelWidth: 1920,
                                                    pixelHeight: 1080, duration: 30, layoutSeed: 2)],
                                 owner: ShareParticipant(id: "gran", name: "Gran", isOwner: true), isMine: false)
        let snapshot = LibrarySnapshot(items: library, extras: shared.mediaItems)
        let ids = shared.photoIDs
        #expect(snapshot.allIDs == library.map(\.id) && snapshot.count == 3, "the library is just the library")
        #expect(ids.allSatisfy { snapshot.contains($0) && !snapshot.inLibrary($0) } && snapshot.inLibrary("library-0"))
        #expect(snapshot.item(ids[1])?.kind == .video && snapshot.day(of: ids[0]) == snapshot.day(of: "library-1"))
        let day = snapshot.day(of: "library-1")!
        let sameDay = library.filter { snapshot.day(of: $0.id) == day }.map(\.id)
        #expect(snapshot.ids(on: day) == sameDay && snapshot.countsByDay()[day] == sameDay.count, "its days count only the library's photos")
        #expect(ids.allSatisfy { (snapshot.position(of: $0) ?? 0) >= 3 })
        #expect(snapshot.counts(of: ids) == (photos: 1, videos: 1))
        var favorite = library[0]
        favorite.isFavorite = true
        #expect(snapshot.updating([favorite]).item(ids[1]) != nil && snapshot.replacingExtras([]).item(ids[0]) == nil)
    }

    @Test func theStoreKeepsSharedAlbums() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SharingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SharedAlbumsStore(folder: folder)
        #expect(store.load().isEmpty)
        let (album, items, catalog) = workedAlbum()
        var shared = SharedAlbum.sharing(album, items: items, catalog: catalog, cover: nil, owner: owner, previous: nil)
        shared.url = URL(string: "https://example.com/share/2")
        try store.save([shared])
        #expect(store.load() == [shared], "read back just as it was saved, to the fraction of a second")
        let picture = store.pictureURL(album: shared.id, item: shared.items[0])
        #expect(picture.pathExtension == "heic" && picture.deletingLastPathComponent().lastPathComponent == shared.id.uuidString)
        var video = shared.items[5]
        video.fileName = nil
        #expect(store.pictureURL(album: shared.id, item: video).pathExtension == "mov")
        try FileManager.default.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
        for item in shared.items.prefix(2) { try Data([1]).write(to: store.pictureURL(album: shared.id, item: item)) }
        store.removePictures(of: shared.id, keeping: [shared.items[0]])
        #expect(FileManager.default.fileExists(atPath: picture.path)
                && !FileManager.default.fileExists(atPath: store.pictureURL(album: shared.id, item: shared.items[1]).path))
    }

    @Test func noticesOfSharedAlbums() {
        let gran = ShareParticipant(id: "gran", name: "Gran", isOwner: true)
        var album = SharedAlbum(id: UUID(), title: "Gran’s Garden", created: Date(), modified: Date(),
                                items: [SharedItem(kind: .photo, date: Date(), pixelWidth: 1, pixelHeight: 1, layoutSeed: 1),
                                        SharedItem(kind: .video, date: Date(), pixelWidth: 1, pixelHeight: 1, layoutSeed: 2)],
                                owner: gran, isMine: false)
        let formatting = Formatting()
        let shared = SharedAlbumNotice.shared(album, formatting: formatting)
        #expect(shared.title == "Gran shared “Gran’s Garden” with you" && shared.body == "1 photo and 1 video. Click to look through it in PugglePhotos.")
        #expect(shared.identifier == "shared-\(album.id.uuidString)")
        var more = album
        more.items += [SharedItem(kind: .photo, date: Date(), pixelWidth: 1, pixelHeight: 1, layoutSeed: 3),
                       SharedItem(kind: .photo, date: Date(), pixelWidth: 1, pixelHeight: 1, layoutSeed: 4)]
        let added = SharedAlbumNotice.added(from: album, to: more, formatting: formatting)
        #expect(added?.title == "Gran added to “Gran’s Garden”" && added?.body == "2 photos added. Click to see them.")
        album.items[0].caption = "Roses"
        #expect(SharedAlbumNotice.added(from: more, to: album, formatting: formatting) == nil, "nothing added, nothing to say")
    }

    @Test func sharedPhotosStayOutOfYourAlbums() {
        var catalog = Catalog()
        let shared = SharedAlbum.photoID(album: UUID(), item: UUID())
        let album = catalog.addAlbum(title: "Mine", items: ["library-1", shared])
        #expect(catalog.album(album)?.items == ["library-1"])
        #expect(catalog.add([shared, "library-2"], toAlbum: album) == 1 && catalog.album(album)?.items == ["library-1", "library-2"])
        catalog.setCaption("Hers", for: [shared])
        catalog.setNote("Hers", for: shared)
        let label = catalog.addLabel(name: "Family", color: .blue)
        catalog.setLabel(label, on: [shared], true)
        #expect(catalog.photos[shared] == nil, "what's said about it is its owner's")
    }

    @Test func aSharedAlbumShowsItsPhotos() {
        let gran = ShareParticipant(id: "gran", name: "Gran", isOwner: true)
        let album = SharedAlbum(id: UUID(), title: "Garden", created: Date(), modified: Date(),
                                items: [SharedItem(kind: .photo, date: Date(timeIntervalSinceReferenceDate: 2), pixelWidth: 1, pixelHeight: 1,
                                                   caption: "Roses", layoutSeed: 1),
                                        SharedItem(kind: .photo, date: Date(timeIntervalSinceReferenceDate: 1), pixelWidth: 1, pixelHeight: 1, layoutSeed: 2)],
                                owner: gran, isMine: false)
        let arranger = Arranger(snapshot: LibrarySnapshot(items: media(2), extras: album.mediaItems), catalog: Catalog(), sharedAlbums: [album])
        #expect(arranger.ids(for: .sharedAlbum(album.id)) == album.photoIDs, "in the album's order")
        #expect(arranger.ids(for: .library) == ["library-0", "library-1"])
        #expect(arranger.title(of: album.photoIDs[0]) == "Roses")
        #expect(arranger.sorted(album.photoIDs, by: .dateTaken, ascending: true) == album.photoIDs.reversed())
    }

    @Test func initials() {
        #expect(ShareParticipant(id: "1", name: "Jamie Rivera").initials == "JR")
        #expect(ShareParticipant(id: "2", name: "Gran").initials == "G")
        #expect(ShareParticipant(id: "3", name: "", address: "sam@example.com").initials == "S")
        #expect(ShareParticipant(id: "4", name: "Mary-Kate O Brien").initials == "MB")
    }
}
