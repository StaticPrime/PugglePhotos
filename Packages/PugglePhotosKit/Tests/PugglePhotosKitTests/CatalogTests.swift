import Foundation
import Testing
@testable import PugglePhotosKit

@Suite struct CatalogTests {
    @Test func albumsKeepEachPhotoOnce() {
        var catalog = Catalog()
        let id = catalog.addAlbum(title: "Beach", items: ["a", "b", "a"])
        #expect(catalog.album(id)?.items == ["a", "b"])
        #expect(catalog.add(["b", "c", "c", "d"], toAlbum: id) == 2)
        #expect(catalog.album(id)?.items == ["a", "b", "c", "d"])
    }

    @Test func aPhotoCanBeInManyAlbums() {
        var catalog = Catalog()
        let beach = catalog.addAlbum(title: "Beach", items: ["a", "b"])
        let summer = catalog.addAlbum(title: "Summer", items: ["b", "c"])
        let membership = Membership(catalog)
        #expect(membership.albums(containing: "b") == [beach, summer])
        #expect(membership.albums(containing: "a") == [beach])
        #expect(membership.albums(containing: "z").isEmpty)
    }

    @Test func removingTheCoverFallsBack() {
        var catalog = Catalog()
        let id = catalog.addAlbum(title: "Beach", items: ["a", "b", "c"])
        catalog.setCover("b", of: id)
        catalog.remove(["b"], fromAlbum: id)
        #expect(catalog.album(id)?.items == ["a", "c"])
        #expect(catalog.album(id)?.cover == nil)
    }

    @Test func movingWithinAnAlbum() {
        var catalog = Catalog()
        let id = catalog.addAlbum(title: "Trip", items: ["a", "b", "c", "d", "e"])
        catalog.move(["d", "b"], inAlbum: id, toIndex: 1)
        #expect(catalog.album(id)?.items == ["a", "d", "b", "c", "e"])
        catalog.move(["a"], inAlbum: id, toIndex: 5)
        #expect(catalog.album(id)?.items == ["d", "b", "c", "e", "a"])
        catalog.move(["x"], inAlbum: id, toIndex: 0)
        #expect(catalog.album(id)?.items == ["x", "d", "b", "c", "e", "a"])
    }

    @Test func renamingDeletingAndTitles() {
        var catalog = Catalog()
        #expect(catalog.unusedAlbumTitle() == "Untitled Album")
        let first = catalog.addAlbum(title: catalog.unusedAlbumTitle())
        #expect(catalog.unusedAlbumTitle() == "Untitled Album 2")
        catalog.renameAlbum(first, to: "Grandma’s Garden")
        catalog.setAlbumNote(first, to: "Every summer since 1998.")
        #expect(catalog.album(first)?.title == "Grandma’s Garden")
        #expect(catalog.album(first)?.note == "Every summer since 1998.")
        catalog.deleteAlbum(first)
        #expect(catalog.albums.isEmpty)
    }

    @Test func labelsGoOnAndOff() {
        var catalog = Catalog()
        let family = catalog.addLabel(name: "Family", color: .pink, emoji: "❤️")
        let funny = catalog.addLabel(name: "Funny", color: .yellow)
        catalog.setLabel(family, on: ["a", "b"], true)
        catalog.setLabel(funny, on: ["b"], true)
        #expect(catalog.details("b").labels == [family, funny])
        // Toggling when only some have it puts it on all of them; again takes it off.
        catalog.toggleLabel(funny, on: ["a", "b"])
        #expect(catalog.details("a").labels == [family, funny])
        catalog.toggleLabel(funny, on: ["a", "b"])
        #expect(catalog.details("a").labels == [family])
        #expect(catalog.details("b").labels == [family])
        catalog.deleteLabel(family)
        #expect(catalog.photos.isEmpty)
        #expect(catalog.labels.map(\.id) == [funny])
        #expect(catalog.label(funny)?.displayName == "Funny")
    }

    @Test func captionsAndNotes() {
        var catalog = Catalog()
        catalog.setCaption("First swim", for: ["a"])
        catalog.setNote("She wouldn’t get out of the water.", for: "a")
        #expect(catalog.details("a") == PhotoDetails(caption: "First swim", note: "She wouldn’t get out of the water."))
        catalog.setCaption("", for: ["a"])
        catalog.setNote("", for: "a")
        #expect(catalog.photos["a"] == nil)
    }
}

@Suite struct CatalogStoreTests {
    func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PugglePhotosKitTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func sample() -> Catalog {
        var catalog = Catalog()
        let album = catalog.addAlbum(title: "Lake", items: ["p1", "p2"], created: date(2026, 1, 2))
        catalog.setCover("p2", of: album)
        let label = catalog.addLabel(name: "Family", color: .pink, emoji: "👪")
        catalog.setLabel(label, on: ["p1"], true)
        catalog.setCaption("Sunset", for: ["p2"])
        return catalog
    }

    @Test func roundTrip() throws {
        let store = CatalogStore(folder: temporaryFolder())
        #expect(try store.load() == Catalog())
        let catalog = sample()
        try store.save(catalog)
        #expect(try store.load() == catalog)
    }

    @Test func anAlbumMadeNowReadsBackExactly() throws {
        var catalog = Catalog()
        catalog.addAlbum(title: "Today", items: ["a"], created: Date())
        #expect(try CatalogStore.decode(CatalogStore.encode(catalog)) == catalog)
    }

    @Test func photosAreWrittenAsAnObjectWithoutEmptyFields() throws {
        let data = try CatalogStore.encode(sample())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let photos = json["photos"] as! [String: [String: Any]]
        #expect(Set(photos.keys) == ["p1", "p2"])
        #expect(photos["p2"]?.keys.sorted() == ["caption"])
        #expect(json["version"] as? Int == 1)
    }

    @Test func oneBackupPerDayForTwoWeeks() throws {
        let store = CatalogStore(folder: temporaryFolder())
        try store.save(sample(), now: date(2026, 1, 1))
        #expect(store.backups().isEmpty)
        for day in 1...20 {
            try store.save(sample(), now: date(2026, 1, day))
            try store.save(sample(), now: date(2026, 1, day, 18))
        }
        let names = store.backups().map(\.lastPathComponent)
        #expect(names.count == CatalogStore.backupDays)
        #expect(names.first == "Catalog 2026-01-20.json")
    }

    @Test func anUnreadableFileIsMovedAsideNotLost() throws {
        let folder = temporaryFolder()
        let store = CatalogStore(folder: folder)
        try Data("{ not json".utf8).write(to: store.fileURL)
        #expect(throws: CatalogStore.StoreError.self) { try store.load() }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(kept.contains { $0.hasPrefix("Catalog (unreadable") })
    }

    @Test func aNewerCatalogIsRefused() throws {
        let store = CatalogStore(folder: temporaryFolder())
        try Data(#"{"version": 99, "albums": []}"#.utf8).write(to: store.fileURL)
        #expect(throws: CatalogStore.StoreError.self) { try store.load() }
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func missingFieldsReadAsEmpty() throws {
        let catalog = try CatalogStore.decode(Data(#"{"albums": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "Old", "note": "", "created": "2026-01-02T00:00:00Z", "items": ["x"], "order": "custom"}]}"#.utf8))
        #expect(catalog.albums.first?.title == "Old")
        #expect(catalog.labels.isEmpty && catalog.photos.isEmpty)
    }
}
