import Foundation
import Testing
@testable import PugglePhotosKit

@Suite struct JournalTests {
    @Test func entriesAreWrittenAndCleared() throws {
        var catalog = Catalog()
        let day = CivilDay(year: 2025, month: 6, day: 14)
        catalog.setEntry("Best beach day ever.", mood: "🥳", for: day, edited: date(2025, 6, 14, 21))
        #expect(catalog.entry(for: day)?.text == "Best beach day ever." && catalog.entry(for: day)?.mood == "🥳")
        #expect(catalog.journal.keys.sorted() == ["2025-06-14"])
        catalog.setEntry("Snow!", mood: "", for: CivilDay(year: 2024, month: 1, day: 14))
        #expect(catalog.journalDays == [day, CivilDay(year: 2024, month: 1, day: 14)])
        #expect(try CatalogStore.decode(CatalogStore.encode(catalog)) == catalog, "the journal is saved")
        catalog.setEntry("\n Sand everywhere.\n\n", mood: "", for: day)
        #expect(catalog.entry(for: day)?.text == "Sand everywhere.", "blank lines around it are dropped")
        catalog.setEntry("  ", mood: "", for: day)
        #expect(catalog.entry(for: day) == nil, "an empty entry is removed")
    }

    @Test func daysReadFromText() {
        #expect(CivilDay("2024-02-29") == CivilDay(year: 2024, month: 2, day: 29))
        #expect(CivilDay("2025-02-29") == nil)
        #expect(CivilDay("2025-13-01") == nil && CivilDay("hello") == nil)
        #expect(CivilDay(CivilDay(year: 1999, month: 12, day: 31).description) == CivilDay(year: 1999, month: 12, day: 31))
    }

    @Test func undoingOtherChangesRestoresTheJournal() {
        var before = Catalog()
        before.setEntry("Old words", mood: "", for: CivilDay(year: 2025, month: 1, day: 1))
        var live = before
        live.setEntry("New words", mood: "😊", for: CivilDay(year: 2025, month: 1, day: 1))
        #expect(before.keepingAlbumContents(from: live).entry(for: CivilDay(year: 2025, month: 1, day: 1))?.text == "Old words")
    }

    @Test func searchFindsWhatWasWritten() {
        var fixture = Fixture()
        fixture.catalog.setEntry("Grandpa taught everyone to skip stones.", mood: "🥰", for: CivilDay(year: 2025, month: 6, day: 14))
        let formatting = Formatting(locale: Locale(identifier: "en_US"), calendar: calendar())
        let found = PhotoSearch("stones", formatting: formatting).filter(fixture.snapshot.allIDs, using: fixture.arranger)
        #expect(found == ["p1", "p2", "p3"], "every photo from the day written about")
        #expect(PhotoSearch("🥰", formatting: formatting).filter(fixture.snapshot.allIDs, using: fixture.arranger).count == 3, "and its mood")
    }

    @Test func aDaysPhotosAreFound() {
        let snapshot = Fixture().snapshot
        #expect(snapshot.ids(on: CivilDay(year: 2025, month: 6, day: 14)) == ["p1", "p2", "p3"], "oldest first")
        #expect(snapshot.ids(on: CivilDay(year: 2025, month: 12, day: 25)) == ["p4"])
        #expect(snapshot.ids(on: CivilDay(year: 2026, month: 2, day: 1)) == ["p5"], "the last day")
        #expect(snapshot.ids(on: CivilDay(year: 2025, month: 6, day: 15)).isEmpty)
        #expect(snapshot.ids(on: CivilDay(year: 1990, month: 1, day: 1)).isEmpty && snapshot.ids(on: CivilDay(year: 2030, month: 1, day: 1)).isEmpty)
        #expect(LibrarySnapshot.empty.ids(on: CivilDay(year: 2025, month: 6, day: 14)).isEmpty)
    }

    @Test func slideshowsQuoteTheJournal() {
        #expect(SlideshowPlan.quote("") == "")
        #expect(SlideshowPlan.quote("Sand everywhere.\n\nWorth it.") == "Sand everywhere. Worth it.", "one line")
        let long = String(repeating: "We walked to the lighthouse and back again, ", count: 8)
        let quote = SlideshowPlan.quote(long)
        #expect(quote.count <= 181 && quote.hasSuffix("…") && !quote.hasSuffix(" …") && !quote.hasSuffix(",…"), "cut at a word")
        let fixture = Fixture()
        let finder = MemoryFinder(arranger: fixture.arranger, formatting: Formatting(locale: Locale(identifier: "en_US"), calendar: calendar()),
                                  today: CivilDay(year: 2026, month: 6, day: 14))
        let plain = finder.selection(["p1", "p3"], title: "Lake")!
        let written = Memory(id: plain.id, kind: plain.kind, title: plain.title, subtitle: plain.subtitle, items: plain.items,
                             keyPhoto: plain.keyPhoto, firstDate: plain.firstDate, lastDate: plain.lastDate,
                             note: "The water was freezing and nobody cared one bit.")
        let plainTitle = SlideshowPlan.make(plain, items: fixture.snapshot.item, secondsPerPhoto: 4)[0].duration
        let writtenTitle = SlideshowPlan.make(written, items: fixture.snapshot.item, secondsPerPhoto: 4)[0].duration
        #expect(plainTitle == SlideshowPlan.titleDuration && writtenTitle > plainTitle && writtenTitle <= plainTitle + 6,
                "time to read what was written")
    }

    @Test func aDayWrittenAboutPlaysWithItsEntry() throws {
        var fixture = Fixture()
        let day = CivilDay(year: 2025, month: 6, day: 14)
        fixture.catalog.setEntry("Grandpa taught everyone to skip stones.", mood: "🥰", for: day)
        let finder = MemoryFinder(arranger: fixture.arranger, formatting: Formatting(locale: Locale(identifier: "en_US"), calendar: calendar()),
                                  today: CivilDay(year: 2026, month: 11, day: 17))
        let memory = try #require(finder.day(day))
        #expect(memory.id == "day-2025-06-14" && memory.title == "Saturday, June 14, 2025")
        #expect(Set(memory.items) == ["p1", "p2", "p3"] && memory.note == "Grandpa taught everyone to skip stones.")
        #expect(finder.memory(memory.id)?.items == memory.items, "found again by its ID, for Show Photos")
        #expect(finder.day(CivilDay(year: 2026, month: 2, day: 1)) == nil, "screenshots alone make no slideshow")
        #expect(finder.memory("day-2025-02-30") == nil)
    }
}

@Suite struct MoreMemoryTests {
    @Test func thisWeekFillsInForYearsWithoutTheDay() {
        var items: [MediaItem] = []
        // 2024: nothing on November 17, but five photos on the 15th and 19th. 2023: one photo on the 17th.
        for index in 0..<3 { items.append(MediaItem(id: PhotoID("a\(index)"), date: date(2024, 11, 15, 10, index))) }
        for index in 0..<2 { items.append(MediaItem(id: PhotoID("b\(index)"), date: date(2024, 11, 19, 10, index))) }
        items.append(MediaItem(id: "c", date: date(2023, 11, 17, 9)))
        for index in 0..<5 { items.append(MediaItem(id: PhotoID("d\(index)"), date: date(2023, 11, 16, 9, index))) }
        let finder = MemoryFinder(arranger: Arranger(snapshot: LibrarySnapshot(items: items, timeZone: newYork), catalog: Catalog()),
                                  formatting: Formatting(locale: Locale(identifier: "en_US"), calendar: calendar()),
                                  today: CivilDay(year: 2026, month: 11, day: 17))
        let week = finder.thisWeek()
        #expect(week.map(\.title) == ["This Week, 2 Years Ago"], "2023 has the day itself, so only 2024 gets a week")
        #expect(week.first?.items.count == 5 && week.first?.subtitle.contains("Nov 15") == true)
        #expect(finder.page().onThisDay.map(\.title) == ["3 Years Ago Today", "This Week, 2 Years Ago"])
        #expect(finder.memory(week[0].id)?.items.count == 5, "a week memory can be found again by its ID")
    }

    @Test func favoritesAndJournalDaysAreCollections() {
        var items: [MediaItem] = []
        for index in 0..<8 { items.append(MediaItem(id: PhotoID("f\(index)"), date: date(2020, 3, index + 1, 12), isFavorite: index < 6)) }
        items.append(MediaItem(id: "shot", kind: .screenshot, date: date(2020, 4, 1), isFavorite: true))
        var catalog = Catalog()
        catalog.setEntry("Spring at last.", mood: "😌", for: CivilDay(year: 2020, month: 3, day: 1))
        catalog.setEntry("Rain.", mood: "", for: CivilDay(year: 2020, month: 3, day: 2))
        catalog.setEntry("No photos this day.", mood: "", for: CivilDay(year: 2020, month: 5, day: 5))
        let finder = MemoryFinder(arranger: Arranger(snapshot: LibrarySnapshot(items: items, timeZone: newYork), catalog: catalog),
                                  formatting: Formatting(locale: Locale(identifier: "en_US"), calendar: calendar()),
                                  today: CivilDay(year: 2026, month: 3, day: 1))
        let favorites = finder.favorites()
        #expect(favorites?.title == "Your Favorites" && favorites?.items.count == 6, "screenshots aren't favorites here")
        let journal = finder.journal()
        #expect(journal?.title == "Days You Wrote About" && journal?.subtitle == "2 days" && journal?.items == ["f0", "f1"])
        #expect(finder.page().collections.map(\.title) == ["Your Favorites", "Days You Wrote About"])
        #expect(finder.onThisDay().first?.note == "Spring at last.", "a day's memory carries what was written that day")
    }

    @Test func notificationsMentionTheJournal() {
        var fixture = MemoryFixture()
        fixture.catalog.setEntry("Hot cocoa and a long walk.", mood: "", for: CivilDay(year: 2025, month: 6, day: 12))
        let plan = MemoryNotifications.plan(finder: fixture.finder, from: CivilDay(year: 2026, month: 6, day: 12), days: 1, hour: 9, minute: 0)
        #expect(plan.first?.body == "10 photos from Thursday, June 12, 2025, and what you wrote that day. Click to watch them as a slideshow.")
    }
}
