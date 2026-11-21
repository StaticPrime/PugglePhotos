import Foundation
import Testing
@testable import PugglePhotosKit

@Suite struct CopyNameTests {
    @Test func aCopyIsNumberedBeforeItsExtension() {
        #expect(CopyNames.name(for: "FileName.jpg", taken: ["FileName.jpg"]) == "FileName(1).jpg")
        #expect(CopyNames.name(for: "IMG_2104.HEIC", taken: []) == "IMG_2104(1).HEIC")
        #expect(CopyNames.name(for: "Pug Zoomies.mov", taken: []) == "Pug Zoomies(1).mov")
    }

    @Test func anotherCopyTakesTheNextNumber() {
        #expect(CopyNames.name(for: "FileName.jpg", taken: ["FileName.jpg", "FileName(1).jpg"]) == "FileName(2).jpg")
        #expect(CopyNames.name(for: "FileName.jpg", taken: ["FileName.jpg", "FileName(1).jpg", "FileName(2).jpg"]) == "FileName(3).jpg")
        #expect(CopyNames.name(for: "FileName.jpg", taken: ["FileName(2).jpg"]) == "FileName(1).jpg", "a number no longer used is used again")
    }

    @Test func aCopyOfACopyIsNumberedAgain() {
        #expect(CopyNames.name(for: "FileName(2).jpg", taken: ["FileName.jpg", "FileName(2).jpg"]) == "FileName(2)(1).jpg")
        #expect(CopyNames.name(for: "FileName(1).jpg", taken: ["FileName(1)(1).jpg"]) == "FileName(1)(2).jpg")
    }

    @Test func namesTakenInAnotherCaseAreTaken() {
        #expect(CopyNames.name(for: "FileName.jpg", taken: ["filename(1).JPG"]) == "FileName(2).jpg")
        // "é" written as one letter, or as "e" and an accent.
        #expect(CopyNames.name(for: "Caf\u{E9}.png", taken: ["Cafe\u{301}(1).png"]) == "Caf\u{E9}(2).png")
    }

    @Test func severalCopiesAtOnceEachGetANameOfTheirOwn() {
        #expect(CopyNames.names(for: ["a.jpg", "a.jpg", "b.mov"], taken: ["a.jpg", "b.mov"]) == ["a(1).jpg", "a(2).jpg", "b(1).mov"])
        #expect(CopyNames.names(for: ["A.jpg", "a.JPG"], taken: []) == ["A(1).jpg", "a(2).JPG"])
    }

    @Test func namesWithoutAnExtension() {
        #expect(CopyNames.name(for: "Scan", taken: []) == "Scan(1)")
        #expect(CopyNames.name(for: "trip.2024.heic", taken: []) == "trip.2024(1).heic", "only the last part is the extension")
        #expect(CopyNames.name(for: ".jpg", taken: []) == ".jpg(1)", "a name that starts with a dot has no extension")
        #expect(CopyNames.name(for: "Odd.", taken: []) == "Odd.(1)")
        #expect(CopyNames.name(for: "", taken: []) == "(1)")
    }
}

@Suite struct CatalogCopyTests {
    @Test func aCopyHasWhatsWrittenAboutItsOriginal() {
        var catalog = Catalog()
        let funny = catalog.addLabel(name: "Funny", color: .yellow)
        catalog.setCaption("First jump", for: ["a"])
        catalog.setNote("She counted to three.", for: "a")
        catalog.setLabel(funny, on: ["a"], true)
        catalog.copyDetails([CopiedPhoto(original: "a", copy: "a2"), CopiedPhoto(original: "b", copy: "b2")])
        #expect(catalog.details("a2") == catalog.details("a"))
        #expect(catalog.details("a2").caption == "First jump" && catalog.details("a2").labels == [funny])
        #expect(catalog.photos["b2"] == nil, "a copy of a photo with nothing written about it has nothing either")
        catalog.setCaption("Second jump", for: ["a2"])
        #expect(catalog.details("a").caption == "First jump", "the copy's own afterwards")
    }

    @Test func copiesGoRightAfterTheirOriginalsInAnAlbum() {
        var catalog = Catalog()
        let id = catalog.addAlbum(title: "Trip", items: ["a", "b", "c"])
        catalog.add([CopiedPhoto(original: "c", copy: "c2"), CopiedPhoto(original: "a", copy: "a2"), CopiedPhoto(original: "z", copy: "z2"),
                     CopiedPhoto(original: "a", copy: "a3")], besideOriginalsIn: id)
        #expect(catalog.album(id)?.items == ["a", "a2", "a3", "b", "c", "c2", "z2"], "copies of photos not in the album go at its end")
        catalog.add([CopiedPhoto(original: "b", copy: "a2")], besideOriginalsIn: id)
        #expect(catalog.album(id)?.items == ["a", "a2", "a3", "b", "c", "c2", "z2"], "a copy already in the album stays put")
        catalog.add([CopiedPhoto(original: "a", copy: "shared:album/item")], besideOriginalsIn: id)
        #expect(catalog.album(id)?.items.count == 7, "a photo shared with you never goes in")
    }

    @Test func aDeletedPhotoIsForgottenEverywhere() {
        var catalog = Catalog()
        let label = catalog.addLabel(name: "Pets", color: .brown)
        let trip = catalog.addAlbum(title: "Trip", items: ["a", "b", "c"])
        let other = catalog.addAlbum(title: "Other", items: ["b"])
        catalog.setCover("b", of: trip)
        catalog.setCaption("Waffles", for: ["b"])
        catalog.setLabel(label, on: ["b", "c"], true)
        var book = BookSettings()
        book.overrides["b"] = BookPlacementOverride(angle: 12)
        book.overrides["c"] = BookPlacementOverride(angle: -4)
        book.hidden = ["b"]
        catalog.setBook(book, for: trip)
        catalog.forget(["b", "missing"])
        #expect(catalog.photos["b"] == nil && catalog.details("c").labels == [label])
        #expect(catalog.album(trip)?.items == ["a", "c"] && catalog.album(other)?.items == [])
        #expect(catalog.album(trip)?.cover == nil)
        #expect(catalog.book(trip).overrides.keys.sorted() == ["c"] && catalog.book(trip).hidden.isEmpty)
        #expect(Membership(catalog).photos(labeled: label) == ["c"])
    }

    @Test func forgettingTheOnlyThingInABookGoesBackToItsDefaults() {
        var catalog = Catalog()
        let trip = catalog.addAlbum(title: "Trip", items: ["a"])
        var book = BookSettings()
        book.hidden = ["a"]
        catalog.setBook(book, for: trip)
        catalog.forget(["a"])
        #expect(catalog.album(trip)?.book == nil)
        var unchanged = catalog
        unchanged.forget([])
        #expect(unchanged == catalog)
    }
}
