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

    @Test func photosMovedToAnotherPage() {
        // Two to a page: p0 p1 | p2 p3 | p4 p5 | p6 p7.
        let natural = BookLayout(items: items(8), captions: [:], settings: BookSettings(perPage: .two), coverPhoto: nil)
        let photoPages = natural.pages.indices.filter { natural.pages[$0].kind == .photos }
        let (first, second) = (photoPages[0], photoPages[1])
        var settings = BookSettings(perPage: .two)
        settings.overrides["p3"] = BookPlacementOverride(center: CGPoint(x: 420, y: 600), page: natural.spot(forPhotosOn: first))
        settings.writings = [BookWriting(text: "Beside p3", spot: .photo("p3"), center: CGPoint(x: 300, y: 740))]
        let moved = BookLayout(items: items(8), captions: [:], settings: settings, coverPhoto: nil)
        #expect(moved.find("p3")?.page == first && moved.find("p3")?.placement.center == CGPoint(x: 420, y: 600),
                "a photo moved to another page is there, where it was put down")
        #expect(moved.pages[first].placements.map(\.id) == ["p0", "p1", "p3"], "on top of what was there")
        #expect(moved.pages[second].placements.map(\.id) == ["p2"], "and its own page keeps the rest")
        #expect(moved.pages[second].placements[0].center == natural.pages[second].placements[0].center, "where they were")
        #expect(moved.pages.count == natural.pages.count && moved.homePages["p3"] == second, "the pages stay as they were")
        #expect(moved.pages[second].writings.map(\.text) == ["Beside p3"], "writing beside it stays on its own page")
        #expect(moved.spot(forWritingAt: CGPoint(x: 420, y: 600), onPage: first) != .photo("p3"),
                "and writing put on the page it went to belongs to that page's own photos")
        #expect(moved.anchor(after: first) == .photo("p1"), "a page added after that page still goes after it")
        #expect(natural.takesPhotos(first) && !natural.takesPhotos(2) && natural.spot(forPhotosOn: 2) == nil,
                "photos go on pages of photos, not the title page")

        // An added page takes photos too.
        var withPage = settings
        let extra = BookExtraPage(after: .photo("p5"))
        withPage.extraPages = [extra]
        withPage.overrides["p0"] = BookPlacementOverride(center: CGPoint(x: 300, y: 300), page: .page(extra.id))
        let onAdded = BookLayout(items: items(8), captions: [:], settings: withPage, coverPhoto: nil)
        let added = onAdded.pages.firstIndex { $0.spot == .page(extra.id) }
        #expect(added != nil && onAdded.find("p0")?.page == added && onAdded.takesPhotos(added!), "a photo can go on an added page")

        // A page that's gone sends the photo back to its own; so does being moved "to" its own page.
        var lost = settings
        lost.overrides["p3"]?.page = .page(UUID())
        #expect(BookLayout(items: items(8), captions: [:], settings: lost, coverPhoto: nil).find("p3")?.page == second)
        var home = settings
        home.overrides["p3"]?.page = natural.spot(forPhotosOn: second)
        #expect(BookLayout(items: items(8), captions: [:], settings: home, coverPhoto: nil).pages[second].placements.map(\.id) == ["p2", "p3"])
    }

    @Test func resizingByTheCorner() {
        let placement = BookPlacement(id: "p0", isVideo: false, aspect: 1.5, center: CGPoint(x: 300, y: 360),
                                      imageSize: CGSize(width: 300, height: 200), angle: 12, caption: "")
        for frame in BookFrame.allCases {
            let rect = placement.frameRect(frame)
            func along(_ factor: CGFloat, _ grab: CGPoint = .zero) -> CGPoint {
                placement.page(CGPoint(x: rect.minX + rect.width * factor + grab.x, y: rect.minY + rect.height * factor + grab.y))
            }
            // Dragging the corner a fifth further along the diagonal makes the photo a fifth bigger, wherever on the
            // corner it was taken hold of.
            #expect(abs(placement.resizeFactor(draggingCornerTo: along(1.2), frame: frame) - 1.2) < 1e-9, "\(frame)")
            let grab = CGPoint(x: -4, y: 3)
            #expect(abs(placement.resizeFactor(draggingCornerTo: along(1.2, grab), grab: grab, frame: frame) - 1.2) < 1e-9, "\(frame)")
            // Off the diagonal, it still keeps its shape: what counts is how far along it the pointer is.
            let aside = placement.page(CGPoint(x: rect.minX + rect.width * 1.2 + rect.height * 0.3, y: rect.minY + rect.height * 1.2 - rect.width * 0.3))
            #expect(abs(placement.resizeFactor(draggingCornerTo: aside, frame: frame) - 1.2) < 1e-9, "\(frame)")
            // Its top left corner stays where it was.
            var bigger = placement
            bigger.imageSize = CGSize(width: 360, height: 240)
            bigger.center = placement.center(resizedBy: 1.2, frame: frame)
            let before = placement.corners(frame)[0], after = bigger.corners(frame)[0]
            #expect(hypot(before.x - after.x, before.y - after.y) < 1e-9, "\(frame)")
            // A long way either way stops at the smallest a photo gets, and at the page's edges.
            let size = placement.frameSize(frame)
            let smallest = placement.resizeFactor(draggingCornerTo: along(0), frame: frame)
            #expect(abs(max(size.width, size.height) * smallest - BookPlacement.smallestFrameSide) < 1e-6, "\(frame)")
            let biggest = placement.resizeFactor(draggingCornerTo: along(9), frame: frame)
            let room = CGSize(width: BookLayout.pageSize.width - 40, height: BookLayout.pageSize.height - 40)
            #expect(size.width * biggest <= room.width + 1e-6 && size.height * biggest <= room.height + 1e-6, "\(frame)")
            #expect(abs(size.width * biggest - room.width) < 1e-6 || abs(size.height * biggest - room.height) < 1e-6, "\(frame)")
        }
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
