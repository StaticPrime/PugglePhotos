import CoreGraphics
import Foundation
import Testing
@testable import PugglePhotosKit

@Suite struct BookTests {
    func items(_ count: Int, aspect: Double = 4.0 / 3) -> [BookItem] {
        (0..<count).map { BookItem(id: PhotoID("p\($0)"), aspect: $0 % 4 == 3 ? 0.75 : aspect, isVideo: $0 == 5) }
    }

    @Test func pagesRunFromCoverToBack() {
        let layout = BookLayout(items: items(7), captions: [:], settings: BookSettings(perPage: .two), coverPhoto: "p0")
        #expect(layout.pages.map(\.kind) == [.cover, .insideCover, .title, .photos, .photos, .photos, .photos, .blank, .insideCover, .back])
        #expect(layout.pages.filter { $0.kind == .photos }.map(\.placements.count) == [2, 2, 2, 1])
        #expect(layout.pages[3].number == 1 && layout.pages[6].number == 4)
        #expect(layout.pages[2].placements.map(\.id) == ["p0"], "the title page shows the cover photo")
        #expect(layout.pages.count % 2 == 0, "a blank page finishes the sheet")
        let even = BookLayout(items: items(6), captions: [:], settings: BookSettings(perPage: .two), coverPhoto: nil)
        #expect(even.pages.count == 8 && !even.pages.contains { $0.kind == .blank })
    }

    @Test func readingTheBook() {
        let layout = BookLayout(items: items(7), captions: [:], settings: BookSettings(perPage: .two), coverPhoto: nil)
        // Ten pages: the closed front, four spreads, the closed back.
        #expect(layout.pages.count == 10 && layout.stateCount == 6)
        #expect(layout.state(0) == (nil, 0))
        #expect(layout.state(1) == (1, 2))
        #expect(layout.state(4) == (7, 8))
        #expect(layout.state(5) == (9, nil))
        #expect(layout.leafTurningForward(from: 0)! == (0, 1), "opening the cover")
        #expect(layout.leafTurningForward(from: 2)! == (4, 5))
        #expect(layout.leafTurningForward(from: 4)! == (8, 9), "closing the back cover")
        #expect(layout.leafTurningForward(from: 5) == nil)
        #expect(layout.state(showing: 0) == 0 && layout.state(showing: 3) == 2 && layout.state(showing: 4) == 2 && layout.state(showing: 9) == 5)
    }

    @Test func framesStayOnThePage() {
        let page = CGRect(origin: .zero, size: BookLayout.pageSize).insetBy(dx: -1, dy: -1)
        for frame in BookFrame.allCases {
            for seed in 1...40 as ClosedRange<UInt64> {
                let settings = BookSettings(frame: frame, tilt: .playful, perPage: .mixed, seed: seed)
                let layout = BookLayout(items: items(12), captions: ["p1": "Cannonball!"], settings: settings, coverPhoto: "p2")
                for placement in layout.pages.flatMap(\.placements) {
                    for corner in placement.corners(frame) {
                        #expect(page.contains(corner), "\(frame) seed \(seed) \(placement.id) corner \(corner)")
                    }
                }
            }
        }
    }

    @Test func framesHaveTheRightShape() {
        let instant = BookLayout(items: items(3), captions: [:], settings: BookSettings(frame: .instant, perPage: .one), coverPhoto: nil)
        let picture = instant.pages[3].placements[0]
        #expect(picture.imageSize.width == picture.imageSize.height, "instant photos are square")
        #expect(picture.frameSize(.instant).height > picture.frameSize(.instant).width, "with room to write underneath")
        let prints = BookLayout(items: items(3), captions: [:], settings: BookSettings(frame: .print, perPage: .one), coverPhoto: nil)
        let print = prints.pages[3].placements[0]
        #expect(abs(print.imageSize.width / print.imageSize.height - 4.0 / 3) < 0.001, "prints keep the photo's shape")
    }

    @Test func theSameSettingsGiveTheSameBook() {
        let a = BookLayout(items: items(20), captions: [:], settings: BookSettings(seed: 5), coverPhoto: nil)
        let b = BookLayout(items: items(20), captions: [:], settings: BookSettings(seed: 5), coverPhoto: nil)
        let c = BookLayout(items: items(20), captions: [:], settings: BookSettings(seed: 6), coverPhoto: nil)
        #expect(a.pages == b.pages)
        #expect(a.pages != c.pages, "shuffling lays it out afresh")
        let straight = BookLayout(items: items(20), captions: [:], settings: BookSettings(tilt: .none), coverPhoto: nil)
        #expect(straight.pages.flatMap(\.placements).allSatisfy { $0.angle == 0 })
    }

    @Test func movesTurnsAndSizesOverrideTheLayout() {
        var settings = BookSettings(perPage: .two)
        settings.overrides["p1"] = BookPlacementOverride(center: CGPoint(x: 200, y: 300), angle: -12, scale: 0.5)
        settings.overrides["p2"] = BookPlacementOverride(center: CGPoint(x: 5000, y: -40))
        let plain = BookLayout(items: items(4), captions: [:], settings: BookSettings(perPage: .two), coverPhoto: nil)
        let layout = BookLayout(items: items(4), captions: [:], settings: settings, coverPhoto: nil)
        let moved = layout.find("p1")!.placement
        #expect(moved.center == CGPoint(x: 200, y: 300) && moved.angle == -12)
        #expect(abs(moved.imageSize.width - plain.find("p1")!.placement.imageSize.width / 2) < 0.001)
        #expect(layout.find("p2")!.placement.center == CGPoint(x: 560, y: 40), "a frame's middle stays on the page")
    }

    @Test func photosLeftOutAndCaptions() {
        let settings = BookSettings(frame: .print, perPage: .two, hidden: ["p1"])
        let layout = BookLayout(items: items(4), captions: ["p2": "Grandma’s pie"], settings: settings, coverPhoto: nil)
        #expect(layout.find("p1") == nil)
        #expect(layout.pages.flatMap(\.placements).map(\.id) == ["p0", "p2", "p3"])
        let captioned = layout.find("p2")!.placement
        #expect(captioned.caption == "Grandma’s pie")
        #expect(captioned.captionRect(.print).minY > captioned.frameRect(.print).maxY, "a print's caption goes under it")
        let instant = BookLayout(items: items(2), captions: ["p0": "Hi"], settings: BookSettings(), coverPhoto: nil).find("p0")!.placement
        #expect(instant.frameRect(.instant).contains(instant.captionRect(.instant)), "an instant photo's caption goes in its frame")
    }

    @Test func findingThePhotoUnderThePointer() {
        let layout = BookLayout(items: items(2), captions: [:], settings: BookSettings(tilt: .playful, perPage: .two), coverPhoto: nil)
        let first = layout.pages[3].placements[0]
        #expect(layout.placement(at: first.center, onPage: 3)?.id == first.id)
        let corner = first.page(CGPoint(x: first.frameRect(.instant).maxX - 3, y: first.frameRect(.instant).maxY - 3))
        #expect(first.contains(corner, frame: .instant))
        #expect(layout.placement(at: CGPoint(x: 3, y: 3), onPage: 3) == nil)
        let back = first.local(first.page(CGPoint(x: 17, y: -23)))
        #expect(abs(back.x - 17) < 0.0001 && abs(back.y + 23) < 0.0001)
    }

    @Test func bookSettingsAreSaved() throws {
        var catalog = Catalog()
        let album = catalog.addAlbum(title: "Lake", items: ["a"])
        #expect(catalog.book(album) == BookSettings())
        var settings = BookSettings(paper: .black, frame: .taped, tilt: .playful, perPage: .three, cover: .navy, seed: 9)
        settings.overrides["a"] = BookPlacementOverride(center: CGPoint(x: 10, y: 20), angle: 3)
        settings.hidden = ["b"]
        catalog.setBook(settings, for: album)
        #expect(try CatalogStore.decode(CatalogStore.encode(catalog)).book(album) == settings)
        catalog.setBook(BookSettings(), for: album)
        #expect(catalog.album(album)?.book == nil, "default settings aren't stored")
        let future = try JSONDecoder().decode(BookSettings.self, from: Data(#"{"paper": "velvet", "frame": "print"}"#.utf8))
        #expect(future.paper == .cream && future.frame == .print, "choices from a newer version fall back")
    }
}
