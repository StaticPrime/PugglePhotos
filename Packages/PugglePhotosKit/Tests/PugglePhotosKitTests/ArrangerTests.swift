import Foundation
import Testing
@testable import PugglePhotosKit

/// A small library: two days in 2025, one in 2026, with a video, a favorite and file names.
struct Fixture {
    let snapshot: LibrarySnapshot
    var catalog = Catalog()
    let lake: UUID
    let party: UUID
    let family: UUID
    let funny: UUID

    init() {
        let items = [
            MediaItem(id: "p3", date: date(2025, 6, 14, 18), fileName: "IMG_10.HEIC"),
            MediaItem(id: "p1", date: date(2025, 6, 14, 9), isFavorite: true, fileName: "IMG_9.HEIC"),
            MediaItem(id: "p2", kind: .video, date: date(2025, 6, 14, 12), duration: 12, fileName: "IMG_0011.MOV"),
            MediaItem(id: "p4", date: date(2025, 12, 25, 8), fileName: "Christmas morning.jpg"),
            MediaItem(id: "p5", kind: .screenshot, date: date(2026, 2, 1, 10), fileName: "Screenshot.png"),
        ]
        snapshot = LibrarySnapshot(items: items, timeZone: newYork)
        lake = catalog.addAlbum(title: "Lake Days", items: ["p3", "p1"], created: date(2026, 3, 1))
        party = catalog.addAlbum(title: "Birthday Party", items: ["p4", "p1"], created: date(2026, 1, 1))
        family = catalog.addLabel(name: "Family", color: .pink)
        funny = catalog.addLabel(name: "Funny", color: .yellow, emoji: "😂")
        catalog.setLabel(family, on: ["p1", "p4"], true)
        catalog.setLabel(funny, on: ["p2"], true)
        catalog.setCaption("Cannonball", for: ["p2"])
        catalog.setNote("Grandpa’s famous pancakes", for: "p4")
    }

    var arranger: Arranger { Arranger(snapshot: snapshot, catalog: catalog) }
}

@Suite struct ArrangerTests {
    let fixture = Fixture()
    var arranger: Arranger { fixture.arranger }

    @Test func snapshotIsInDateOrder() {
        #expect(fixture.snapshot.allIDs == ["p1", "p2", "p3", "p4", "p5"])
        #expect(fixture.snapshot.day(of: "p4") == CivilDay(year: 2025, month: 12, day: 25))
        #expect(fixture.snapshot.counts(of: ["p1", "p2", "zz"]) == (1, 1))
        #expect(fixture.snapshot.countsByDay()[CivilDay(year: 2025, month: 6, day: 14)] == 3)
    }

    @Test func sources() {
        #expect(arranger.ids(for: .library) == ["p1", "p2", "p3", "p4", "p5"])
        #expect(arranger.ids(for: .favorites) == ["p1"])
        #expect(arranger.ids(for: .videos) == ["p2"])
        #expect(arranger.ids(for: .album(fixture.lake)) == ["p3", "p1"])
        #expect(arranger.ids(for: .label(fixture.family)) == ["p1", "p4"])
        #expect(arranger.ids(for: .photosAlbum("x"), photosAlbum: ["p5", "gone", "p2"]) == ["p5", "p2"])
        #expect(arranger.ids(for: .recentlyAdded, recent: ["p4"]) == ["p4"])
        #expect(arranger.ids(for: .allAlbums).isEmpty)
    }

    @Test func sortingByDate() {
        let ids: [PhotoID] = ["p4", "p1", "p3"]
        #expect(arranger.sorted(ids, by: .dateTaken, ascending: true) == ["p1", "p3", "p4"])
        #expect(arranger.sorted(ids, by: .dateTaken, ascending: false) == ["p4", "p3", "p1"])
        #expect(arranger.sorted(ids, by: .custom, ascending: true) == ids)
        #expect(arranger.sorted(ids, by: .custom, ascending: false) == ids.reversed())
    }

    @Test func sortingByTitleUsesCaptionsAndNaturalNumbers() {
        let all = fixture.snapshot.allIDs
        // Titles: p1 IMG_9, p2 "Cannonball", p3 IMG_10, p4 Christmas morning, p5 Screenshot.
        #expect(arranger.sorted(all, by: .title, ascending: true) == ["p2", "p4", "p1", "p3", "p5"])
        #expect(arranger.sorted(all, by: .title, ascending: false) == ["p5", "p3", "p1", "p4", "p2"])
        #expect(Arranger.collationKey("IMG_9") < Arranger.collationKey("img_10"))
        #expect(Arranger.collationKey("Été") == Arranger.collationKey("ete"))
    }

    @Test func untitledPhotosStayLast() {
        let items = [MediaItem(id: "x", date: date(2020, 1, 1)), MediaItem(id: "y", date: date(2020, 1, 2), fileName: "B")]
        let arranger = Arranger(snapshot: LibrarySnapshot(items: items, timeZone: newYork), catalog: Catalog())
        #expect(arranger.sorted(["x", "y"], by: .title, ascending: true) == ["y", "x"])
        #expect(arranger.sorted(["x", "y"], by: .title, ascending: false) == ["y", "x"])
    }

    @Test func sortingByKindAndDateAdded() {
        #expect(arranger.sorted(fixture.snapshot.allIDs, by: .kind, ascending: true) == ["p1", "p3", "p4", "p5", "p2"])
        let added = [MediaItem(id: "x", date: date(2020, 1, 1), addedDate: date(2026, 5, 1)),
                     MediaItem(id: "y", date: date(2021, 1, 1), addedDate: date(2026, 4, 1))]
        let arranger = Arranger(snapshot: LibrarySnapshot(items: added, timeZone: newYork), catalog: Catalog())
        #expect(arranger.sorted(["x", "y"], by: .dateAdded, ascending: true) == ["y", "x"])
    }

    @Test func groupingByDate() {
        let all = fixture.snapshot.allIDs
        let days = arranger.sections(all, arrangement: Arrangement(grouping: .day))
        #expect(days.map(\.key) == [.day(CivilDay(year: 2025, month: 6, day: 14)), .day(CivilDay(year: 2025, month: 12, day: 25)),
                                    .day(CivilDay(year: 2026, month: 2, day: 1))])
        #expect(days[0].items == ["p1", "p2", "p3"])
        let newestFirst = arranger.sections(arranger.sorted(all, by: .dateTaken, ascending: false),
                                            arrangement: Arrangement(grouping: .month, ascending: false))
        #expect(newestFirst.map(\.key) == [.month(year: 2026, month: 2), .month(year: 2025, month: 12), .month(year: 2025, month: 6)])
        #expect(newestFirst.last?.items == ["p3", "p2", "p1"])
        let years = arranger.sections(all, arrangement: Arrangement(grouping: .year))
        #expect(years.map(\.key) == [.year(2025), .year(2026)])
        #expect(arranger.sections(all, arrangement: Arrangement(grouping: .none)).map(\.key) == [.all])
        #expect(arranger.sections([], arrangement: Arrangement(grouping: .none)).isEmpty)
    }

    @Test func groupingByAlbumShowsAPhotoInEveryAlbum() {
        let sections = arranger.sections(fixture.snapshot.allIDs, arrangement: Arrangement(grouping: .album))
        #expect(sections.map(\.key) == [.album(fixture.lake), .album(fixture.party), .noAlbum])
        #expect(sections[0].items == ["p1", "p3"])
        #expect(sections[1].items == ["p1", "p4"])
        #expect(sections[2].items == ["p2", "p5"])
        let reordered = arranger.sections(fixture.snapshot.allIDs, arrangement: Arrangement(grouping: .album),
                                          albumOrder: [fixture.party, fixture.lake])
        #expect(reordered.map(\.key).prefix(2) == [.album(fixture.party), .album(fixture.lake)])
    }

    @Test func groupingByLabel() {
        let sections = arranger.sections(fixture.snapshot.allIDs, arrangement: Arrangement(grouping: .label))
        #expect(sections.map(\.key) == [.label(fixture.family), .label(fixture.funny), .noLabel])
        #expect(sections[2].items == ["p3", "p5"])
    }

    @Test func sectionTitles() {
        let formatting = Formatting(locale: Locale(identifier: "en_US"), calendar: calendar())
        let today = CivilDay(year: 2026, month: 2, day: 1)
        #expect(arranger.title(of: .day(today), formatting: formatting, today: today) == "Today")
        #expect(arranger.title(of: .album(fixture.lake), formatting: formatting, today: today) == "Lake Days")
        #expect(arranger.title(of: .label(fixture.funny), formatting: formatting, today: today) == "😂 Funny")
        #expect(arranger.title(of: .noAlbum, formatting: formatting, today: today) == "Not in an Album")
        #expect(arranger.title(of: .month(year: 2025, month: 12), formatting: formatting, today: today) == "December 2025")
    }

    @Test func sectionDayRanges() {
        #expect(PhotoSection.Key.month(year: 2024, month: 2).days == CivilDay(year: 2024, month: 2, day: 1)...CivilDay(year: 2024, month: 2, day: 29))
        #expect(PhotoSection.Key.year(2025).days?.upperBound == CivilDay(year: 2025, month: 12, day: 31))
        #expect(PhotoSection.Key.noLabel.days == nil)
    }

    @Test func dropsChangeDatesOnlyInDateOrder() {
        #expect(Arrangement.timeline.isDateOrdered)
        #expect(!Arrangement(grouping: .day, sort: .title).isDateOrdered)
        #expect(!Arrangement(grouping: .album).isDateOrdered)
    }

    @Test func albumCoversAndSummaries() {
        var fixture = Fixture()
        let lake = fixture.catalog.album(fixture.lake)!
        #expect(fixture.arranger.cover(of: lake) == "p1")
        fixture.catalog.setAlbumOrder(fixture.lake, to: .custom)
        #expect(fixture.arranger.cover(of: fixture.catalog.album(fixture.lake)!) == "p3")
        fixture.catalog.setCover("p1", of: fixture.lake)
        #expect(fixture.arranger.cover(of: fixture.catalog.album(fixture.lake)!) == "p1")
        let empty = fixture.catalog.addAlbum(title: "Attic Scans", created: date(2026, 5, 1))
        let summary = fixture.arranger.summary(of: fixture.catalog.album(fixture.party)!)
        #expect(summary.photos == 2 && summary.videos == 0 && summary.count == 2)
        #expect(summary.firstDate == date(2025, 6, 14, 9) && summary.lastDate == date(2025, 12, 25, 8))
        let byName = fixture.arranger.albumSummaries(sort: .name, ascending: true).map(\.title)
        #expect(byName == ["Attic Scans", "Birthday Party", "Lake Days"])
        let byDate = fixture.arranger.albumSummaries(sort: .date, ascending: false).map(\.id)
        #expect(byDate == [empty, fixture.lake, fixture.party] || byDate == [empty, fixture.party, fixture.lake])
        let byCreated = fixture.arranger.albumSummaries(sort: .created, ascending: true).map(\.id)
        #expect(byCreated == [fixture.party, fixture.lake, empty])
        let byCount = fixture.arranger.albumSummaries(sort: .count, ascending: false).map(\.id)
        #expect(byCount.last == empty)
    }
}

@Suite struct SearchTests {
    let fixture = Fixture()
    let formatting = Formatting(locale: Locale(identifier: "en_US"), calendar: calendar())

    func search(_ text: String) -> [PhotoID] {
        PhotoSearch(text, formatting: formatting).filter(fixture.snapshot.allIDs, using: fixture.arranger)
    }

    @Test func findsByWhatPeopleRemember() {
        #expect(search("cannonball") == ["p2"])
        #expect(search("PANCAKES") == ["p4"])
        #expect(search("family") == ["p1", "p4"])
        #expect(search("😂") == ["p2"])
        #expect(search("lake") == ["p1", "p3"])
        #expect(search("videos") == ["p2"])
        #expect(search("screenshot") == ["p5"])
        #expect(search("favorites") == ["p1"])
        #expect(search("2026") == ["p5"])
        #expect(search("june") == ["p1", "p2", "p3"])
        #expect(search("dec") == ["p4"])
        #expect(search("img_10") == ["p3"])
    }

    @Test func everyWordMustMatch() {
        #expect(search("family june") == ["p1"])
        #expect(search("family 2026").isEmpty)
        #expect(search("   ").count == 5)
        #expect(PhotoSearch("  ").isEmpty)
    }
}
