import CoreGraphics
import Foundation
import Testing
@testable import PugglePhotosKit

@Suite struct BookNotesTests {
    func items(_ count: Int) -> [BookItem] {
        (0..<count).map { BookItem(id: PhotoID("p\($0)"), aspect: 4.0 / 3) }
    }

    func placement(_ layout: BookLayout, _ id: PhotoID) -> BookPlacement { layout.find(id)!.placement }

    @Test func notesFollowTheFrames() {
        let notes: [PhotoID: String] = ["p0": "First swim of the summer.", "p1": "Grandma's pie."]
        let instant = BookLayout(items: items(3), captions: [:], notes: notes, settings: BookSettings(frame: .instant), coverPhoto: "p0")
        #expect(placement(instant, "p0").noteStyle == .onPhoto, "an instant photo's note is written in its white space")
        #expect(placement(instant, "p0").note == "First swim of the summer." && placement(instant, "p0").showsNote)
        #expect(!placement(instant, "p2").showsNote, "a photo without a note shows none")
        #expect(instant.pages[2].placements.first?.showsNote == false, "the title page's photo has no note")
        let prints = BookLayout(items: items(3), captions: [:], notes: notes, settings: BookSettings(frame: .print), coverPhoto: nil)
        #expect(placement(prints, "p0").noteStyle == .underPhoto, "other photos' notes go on the page under them")
        var settings = BookSettings(frame: .instant, notes: .sticky)
        settings.changeOverride("p1") { $0.noteStyle = .hidden }
        let chosen = BookLayout(items: items(3), captions: [:], notes: notes, settings: settings, coverPhoto: nil)
        #expect(placement(chosen, "p0").hasSticky, "the book's choice applies to every photo")
        #expect(!placement(chosen, "p1").showsNote && !placement(chosen, "p1").hasSticky, "and each photo can hide its own")
        #expect(BookNoteStyle.onPhoto.displayName(for: .instant) == "Written in the White Space")
    }

    @Test func notesUnderPhotosHaveRoom() {
        let settings = BookSettings(frame: .print, tilt: .none, perPage: .one, notes: .underPhoto)
        let tall = [BookItem(id: "p0", aspect: 0.75)]
        let plain = BookLayout(items: tall, captions: [:], settings: settings, coverPhoto: nil)
        let noted = BookLayout(items: tall, captions: [:], notes: ["p0": "The day the boat finally floated."], settings: settings, coverPhoto: nil)
        let without = placement(plain, "p0"), with = placement(noted, "p0")
        #expect(with.imageSize.height < without.imageSize.height && with.center.y < without.center.y, "the photo makes room for the note")
        let note = with.noteRect(.print), frame = with.frameRect(.print)
        #expect(note.minY > frame.maxY && note.width > frame.width && note.width < frame.width + 20,
                "the note is written under the frame, no wider than it by much")
        let bottom = with.page(CGPoint(x: note.midX, y: note.maxY))
        #expect(bottom.y < BookLayout.pageSize.height, "and stays on the page")
    }

    @Test func instantNotesShareTheWhiteSpaceWithTheCaption() {
        let layout = BookLayout(items: items(1), captions: ["p0": "Lake Day"], notes: ["p0": "Mia swam to the raft."],
                                settings: BookSettings(frame: .instant), coverPhoto: nil)
        let photo = placement(layout, "p0")
        let caption = photo.captionRect(.instant), note = photo.noteRect(.instant), picture = photo.imageRect(.instant)
        #expect(caption.minY >= picture.maxY && note.minY >= caption.maxY - 1, "the caption, then the note, under the picture")
        #expect(note.maxY <= photo.frameRect(.instant).maxY, "both inside the frame")
    }

    @Test func stickyNotesStayWithTheirPhotos() {
        var settings = BookSettings(frame: .print, notes: .sticky)
        let notes: [PhotoID: String] = ["p0": "Best day."]
        let layout = BookLayout(items: items(2), captions: [:], notes: notes, settings: settings, coverPhoto: nil)
        let photo = placement(layout, "p0")
        let frame = photo.frameRect(.print)
        #expect(photo.sticky.center.x > frame.midX && photo.sticky.center.y < frame.midY, "over the top right corner")
        #expect(photo.sticky.center.y - photo.sticky.size.height / 2 < frame.minY, "hanging off the photo a little")
        let middle = photo.stickyPage(.zero)
        #expect(photo.stickyContains(middle) && layout.sticky(at: middle, onPage: layout.find("p0")!.page)?.id == "p0")
        // Moving the photo carries its sticky note along.
        settings.changeOverride("p0") { $0.center = CGPoint(x: photo.center.x - 40, y: photo.center.y + 30) }
        let moved = placement(BookLayout(items: items(2), captions: [:], notes: notes, settings: settings, coverPhoto: nil), "p0")
        let shift = CGPoint(x: moved.stickyPage(.zero).x - middle.x, y: moved.stickyPage(.zero).y - middle.y)
        #expect(abs(shift.x + 40) < 0.01 && abs(shift.y - 30) < 0.01)
        // Its own place, size and color, once the person changes them.
        let own = BookSticky(center: CGPoint(x: -50, y: 80), size: CGSize(width: 200, height: 90), angle: -6, color: .pink)
        settings.changeOverride("p0") { $0.sticky = own }
        let changed = placement(BookLayout(items: items(2), captions: [:], notes: notes, settings: settings, coverPhoto: nil), "p0")
        #expect(changed.sticky == own && changed.stickyCorners().count == 4)
        #expect(!placement(layout, "p1").stickyContains(placement(layout, "p1").stickyPage(.zero)), "no note, no sticky")
    }

    @Test func addedPagesGoWhereTheyWereAdded() {
        let first = UUID(), second = UUID(), third = UUID(), afterAdded = UUID(), lost = UUID()
        var settings = BookSettings(perPage: .two)
        settings.extraPages = [BookExtraPage(id: first, after: .photo("p1")), BookExtraPage(id: second, after: .photo("p1")),
                               BookExtraPage(id: third, after: .title), BookExtraPage(id: afterAdded, after: .page(first)),
                               BookExtraPage(id: lost, after: .photo("gone"))]
        let layout = BookLayout(items: items(4), captions: [:], settings: settings, coverPhoto: nil)
        let spots = layout.pages.map(\.spot)
        #expect(spots == [.cover, .insideFront, .title, .page(third), .photo("p0"), .page(second), .page(first), .page(afterAdded),
                          .photo("p2"), .page(lost), .insideBack, .back],
                "after the title; after the page of photos, the newest first, each followed by its own; and the rest at the end")
        #expect(layout.pages.compactMap(\.number) == [1, 2, 3, 4, 5, 6, 7], "added pages are numbered with the rest")
        #expect(layout.anchor(after: 2) == .title && layout.anchor(after: 4) == .photo("p1") && layout.anchor(after: 6) == .page(first))
        #expect(layout.anchor(after: 0) == nil && layout.anchor(after: 1) == nil && layout.anchor(after: 11) == nil, "nothing goes after a cover")
        let odd = BookLayout(items: items(3), captions: [:], settings: BookSettings(perPage: .two), coverPhoto: nil)
        #expect(odd.pages[5].kind == .blank && odd.anchor(after: 5) == .photo("p2"), "after the blank page: after the page before it")
        settings.extraPages.append(BookExtraPage(after: .photo("p3")))
        #expect(BookLayout(items: items(4), captions: [:], settings: settings, coverPhoto: nil).pages.count % 2 == 0,
                "a blank page still finishes the last sheet")
    }

    @Test func writingStaysOnItsPage() {
        let added = UUID()
        var settings = BookSettings(perPage: .two)
        settings.extraPages = [BookExtraPage(id: added, after: .title)]
        let spots: [BookSpot] = [.cover, .insideFront, .title, .photo("p3"), .page(added), .insideBack, .back, .photo("p9")]
        settings.writings = spots.map { BookWriting(text: "\($0)", spot: $0, center: CGPoint(x: 300, y: 300)) }
        let layout = BookLayout(items: items(6), captions: [:], settings: settings, coverPhoto: nil)
        for spot in spots.dropLast() {
            let page = layout.page(of: spot)
            #expect(page.map { layout.pages[$0].writings.map(\.spot) } == [spot], "\(spot)")
        }
        #expect(layout.pages.flatMap(\.writings).count == 7, "writing next to a photo that's gone waits for it")
        // Laid out afresh with one photo a page, the writing follows its photo.
        settings.perPage = .one
        let again = BookLayout(items: items(6), captions: [:], settings: settings, coverPhoto: nil)
        #expect(again.pages[again.find("p3")!.page].writings.map(\.text) == ["\(BookSpot.photo("p3"))"])
        // New writing on a page of photos belongs to the photo nearest it.
        let page = layout.find("p3")!.page
        let near = layout.pages[page].placements.first { $0.id == "p3" }!.center
        #expect(layout.spot(forWritingAt: CGPoint(x: near.x + 5, y: near.y + 5), onPage: page) == .photo("p3"))
        #expect(layout.spot(forWritingAt: .zero, onPage: 0) == .cover)
    }

    @Test func writingTurnsAboutItsMiddle() {
        let writing = BookWriting(spot: .title, center: CGPoint(x: 200, y: 300), angle: 30)
        let point = CGPoint(x: 40, y: -12)
        let back = writing.local(writing.page(point))
        #expect(abs(back.x - point.x) < 0.001 && abs(back.y - point.y) < 0.001)
        #expect(BookWriting.widths.contains(writing.width) && BookWriting.sizes.contains(writing.size))
    }

    @Test func newBookSettingsAreSavedAndOldOnesStillLoad() throws {
        var settings = BookSettings(frame: .taped, notes: .sticky, handwriting: "Marker Felt")
        settings.writings = [BookWriting(text: "Summer!", spot: .photo("p1"), center: CGPoint(x: 120, y: 80), angle: -8, ink: .blue)]
        settings.extraPages = [BookExtraPage(after: .page(UUID()))]
        settings.changeOverride("p1") { override in
            override.noteStyle = .hidden
            override.sticky = BookSticky(center: CGPoint(x: 10, y: -20), size: CGSize(width: 150, height: 140), angle: 3, color: .green)
        }
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(BookSettings.self, from: data) == settings)
        let old = Data(#"{"paper":"kraft","frame":"print","tilt":"none","perPage":"two","cover":"navy","seed":3,"overrides":{"p1":{"angle":4}},"hidden":[]}"#.utf8)
        let loaded = try JSONDecoder().decode(BookSettings.self, from: old)
        #expect(loaded.notes == nil && loaded.noteStyle == .underPhoto && loaded.handwriting == nil && loaded.writings.isEmpty)
        #expect(loaded.overrides["p1"]?.angle == 4 && loaded.overrides["p1"]?.sticky == nil)
        var trimmed = settings
        trimmed.changeOverride("p1") { $0 = BookPlacementOverride() }
        #expect(trimmed.overrides["p1"] == nil, "an override with nothing left in it goes")
    }
}
