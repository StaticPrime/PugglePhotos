import Foundation
import Testing
@testable import PugglePhotosKit

/// A library with photos on November 17 in three earlier years, a big trip in June 2025, a screenshot on the day,
/// and a year's worth of photos in 2024.
struct MemoryFixture {
    var catalog = Catalog()
    let snapshot: LibrarySnapshot
    let today = CivilDay(year: 2026, month: 11, day: 17)
    let formatting = Formatting(locale: Locale(identifier: "en_US"), calendar: calendar())
    let lake: UUID
    let family: UUID

    init() {
        var items: [MediaItem] = []
        func add(_ id: String, _ when: Date, kind: MediaKind = .photo, favorite: Bool = false) {
            items.append(MediaItem(id: PhotoID(id), kind: kind, date: when, isFavorite: favorite))
        }
        for index in 0..<4 { add("y25-\(index)", date(2025, 11, 17, 10, index * 10), favorite: index == 2) }
        for index in 0..<3 { add("y23-\(index)", date(2023, 11, 17, 15, index * 10)) }
        add("y20-0", date(2020, 11, 17, 9))
        add("shot", date(2024, 11, 17, 12), kind: .screenshot)
        // A trip: three busy days in a row, and a busy day on its own a week later.
        for day in 12...14 {
            for index in 0..<10 { add("trip-\(day)-\(index)", date(2025, 6, day, 9, index * 5)) }
        }
        for index in 0..<9 { add("party-\(index)", date(2025, 6, 21, 18, index * 5)) }
        // A burst: five shots a second apart.
        for index in 0..<5 { add("burst-\(index)", date(2025, 6, 21, 20, 0, index)) }
        // 2024, a few photos every month.
        for month in 1...12 {
            for index in 0..<3 { add("m24-\(month)-\(index)", date(2024, month, 5, 12, index * 5)) }
        }
        snapshot = LibrarySnapshot(items: items, timeZone: newYork)
        lake = catalog.addAlbum(title: "Lake Week", items: (12...14).flatMap { day in (0..<10).map { PhotoID("trip-\(day)-\($0)") } })
        family = catalog.addLabel(name: "Family", color: .pink, emoji: "❤️")
        catalog.setLabel(family, on: (0..<9).map { PhotoID("party-\($0)") }, true)
        catalog.setCaption("Cake!", for: ["party-4"])
    }

    var arranger: Arranger { Arranger(snapshot: snapshot, catalog: catalog) }
    var finder: MemoryFinder { MemoryFinder(arranger: arranger, formatting: formatting, today: today) }
}

@Suite struct MemoryTests {
    let fixture = MemoryFixture()

    @Test func onThisDayMakesOneMemoryPerYearAndOneForAll() {
        let memories = fixture.finder.onThisDay()
        #expect(memories.map(\.title) == ["1 Year Ago Today", "3 Years Ago Today", "6 Years Ago Today", "This Day Through the Years"])
        #expect(memories[0].items == (0..<4).map { PhotoID("y25-\($0)") })
        #expect(memories[0].subtitle == "Monday, November 17, 2025")
        #expect(memories[0].keyPhoto == "y25-2", "the favorite is the key photo")
        #expect(memories[3].items.count == 8 && memories[3].subtitle == "2020, 2023, and 2025")
        #expect(!memories.flatMap(\.items).contains("shot"), "screenshots aren't memories")
        #expect(memories[0].id == "onthisday-2026-11-17-1")
        #expect(fixture.finder.memory("onthisday-2026-11-17-3")?.items.count == 3, "a memory can be found again by its ID")
    }

    @Test func nothingOnADayWithoutPhotos() {
        #expect(fixture.finder.onThisDay(CivilDay(year: 2026, month: 3, day: 3)).isEmpty)
    }

    @Test func leapDayPhotosShowOnTheTwentyEighth() {
        let items = [MediaItem(id: "leap", date: date(2024, 2, 29, 12))]
        let finder = MemoryFinder(arranger: Arranger(snapshot: LibrarySnapshot(items: items, timeZone: newYork), catalog: Catalog()),
                                  formatting: fixture.formatting, today: CivilDay(year: 2025, month: 2, day: 28))
        #expect(finder.onThisDay().first?.items == ["leap"])
        let leapYearFinder = MemoryFinder(arranger: finder.arranger, formatting: fixture.formatting, today: CivilDay(year: 2028, month: 2, day: 29))
        #expect(leapYearFinder.onThisDay().first?.title == "4 Years Ago Today")
    }

    @Test func busyDaysBecomeHighlights() {
        let highlights = fixture.finder.highlights()
        #expect(highlights.count == 2)
        // The most recent first: the party, named for its label; then the trip, named for its album.
        #expect(highlights[0].title == "Family, June 2025", "\(highlights[0].title)")
        #expect(highlights[1].title == "Lake Week, 2025")
        #expect(highlights[1].items.count == 30 && highlights[1].subtitle.contains("Jun 12"))
        #expect(highlights[0].keyPhoto == "party-4", "the captioned photo is the key photo")
        #expect(highlights[0].id == "event-2025-06-21")
    }

    @Test func tripsLastAtMostAWeek() {
        // Ten busy days in a row make a week's trip and a three-day one.
        var items: [MediaItem] = []
        for day in 1...10 {
            for index in 0..<8 { items.append(MediaItem(id: PhotoID("d\(day)-\(index)"), date: date(2025, 8, day, 9, index * 5))) }
        }
        let finder = MemoryFinder(arranger: Arranger(snapshot: LibrarySnapshot(items: items, timeZone: newYork), catalog: Catalog()),
                                  formatting: fixture.formatting, today: fixture.today)
        let highlights = finder.highlights()
        #expect(highlights.count == 2)
        #expect(highlights.map(\.id) == ["event-2025-08-08", "event-2025-08-01"])
        #expect(highlights.last?.items.count == 40, "a week of 56 photos plays its best 40")
    }

    @Test func burstsKeepOneShot() {
        let party = fixture.finder.highlights()[0]
        let burst = party.items.filter { $0.rawValue.hasPrefix("burst-") }
        #expect(burst.count == 1, "\(burst)")
    }

    @Test func yearsAndLabels() {
        let years = fixture.finder.years()
        #expect(years.map(\.title) == ["2025 in Photos", "2024 in Photos"])
        #expect(years[1].items.count == 36)
        let labels = fixture.finder.labels()
        #expect(labels.map(\.title) == ["❤️ Family"])
        #expect(fixture.finder.page().all.count == 4 + 2 + 2 + 1)
    }

    @Test func curationKeepsTheBestAndSpreadsTheRest() {
        var catalog = fixture.catalog
        catalog.setCaption("Best day", for: ["m24-7-1"])
        let arranger = Arranger(snapshot: fixture.snapshot, catalog: catalog)
        let ids = arranger.ids(for: .library).filter { $0.rawValue.hasPrefix("m24-") }
        let picked = Curator(arranger: arranger).pick(ids, limit: 12)
        #expect(picked.count == 12)
        #expect(picked.contains("m24-7-1"))
        let months = Set(picked.compactMap { fixture.snapshot.day(of: $0)?.month })
        #expect(months.count >= 10, "spread across the year: \(months.sorted())")
        #expect(picked == picked.sorted { (fixture.snapshot.position(of: $0) ?? 0) < (fixture.snapshot.position(of: $1) ?? 0) })
    }

    @Test func albumsAndSelectionsPlayEverything() {
        let album = fixture.finder.album(fixture.lake)
        #expect(album?.items.count == 30 && album?.title == "Lake Week")
        let picked = fixture.finder.selection(["y23-2", "y20-0", "gone"], title: "Picked")
        #expect(picked?.items == ["y23-2", "y20-0"])
    }

    @Test func memoriesPageFindsSources() {
        let arranger = fixture.arranger
        #expect(arranger.ids(for: .memories).isEmpty)
        #expect(arranger.ids(for: .memory("x"), memory: ["y25-0", "gone"]) == ["y25-0"])
    }
}

@Suite struct MemoryNotificationTests {
    let fixture = MemoryFixture()

    @Test func notificationsForDaysWithMemories() {
        let plan = MemoryNotifications.plan(finder: fixture.finder, from: CivilDay(year: 2026, month: 11, day: 15), days: 10, hour: 9, minute: 30)
        #expect(plan.map(\.day) == [CivilDay(year: 2026, month: 11, day: 17)])
        let today = plan[0]
        #expect(today.title == "Memories from This Day")
        #expect(today.body == "Photos from this day in 2020, 2023, and 2025. Click to watch them as a slideshow.")
        #expect(today.date == date(2026, 11, 17, 9, 30))
        #expect(today.memoryID == "onthisday-2026-11-17-all" && today.identifier == "memory-2026-11-17")
    }

    @Test func oneYearReadsSimply() {
        let plan = MemoryNotifications.plan(finder: fixture.finder, from: CivilDay(year: 2026, month: 6, day: 12), days: 1, hour: 9, minute: 0)
        #expect(plan.first?.title == "1 Year Ago Today")
        #expect(plan.first?.body == "10 photos from Thursday, June 12, 2025. Click to watch them as a slideshow.")
        #expect(plan.first?.memoryID == "onthisday-2026-06-12-1")
    }
}

@Suite struct SlideshowTests {
    let fixture = MemoryFixture()

    @Test func slidesHaveATitleEveryPhotoAndAnEnd() {
        var items = fixture.snapshot.items
        items.append(MediaItem(id: "clip", kind: .video, date: date(2025, 11, 17, 11), duration: 40))
        let snapshot = LibrarySnapshot(items: items, timeZone: newYork)
        let memory = Memory(id: "m", kind: .selection, title: "Picked", subtitle: "Sub", items: ["y25-0", "clip", "y25-1"],
                            keyPhoto: "y25-0", firstDate: .distantPast, lastDate: .distantFuture)
        let slides = SlideshowPlan.make(memory, items: snapshot.item, secondsPerPhoto: 5)
        #expect(slides.count == 5)
        #expect(slides[0] == Slide(.title(title: "Picked", subtitle: "Sub", photo: "y25-0"), duration: SlideshowPlan.titleDuration))
        #expect(slides[2] == Slide(.video("clip"), duration: SlideshowPlan.longestVideo), "long videos play their first seconds")
        #expect(slides[3].duration == 5 && slides[3].isCounted && !slides[0].isCounted)
        #expect(slides.last == Slide(.end(title: "Picked"), duration: 0))
        #expect(SlideshowPlan.length(slides) == SlideshowPlan.titleDuration + 5 + SlideshowPlan.longestVideo + 5)
    }

    @Test func kenBurnsStaysInsideThePhoto() {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -1e-9, dy: -1e-9)
        let shapes: [(image: Double, screen: Double)] = [(4.0 / 3, 1.6), (0.75, 1.6), (16.0 / 9, 16.0 / 9), (3.0, 1.6)]
        for seed in 0..<UInt64(300) {
            for shape in shapes {
                let motion = KenBurns.motion(imageAspect: shape.image, screenAspect: shape.screen, seed: seed)
                for rect in [motion.from, motion.to] {
                    #expect(unit.contains(rect))
                    if motion.fills {
                        // The part shown has the screen's shape.
                        let shown = Double(rect.width) * shape.image / Double(rect.height)
                        #expect(abs(shown - shape.screen) < 1e-6)
                    }
                }
                #expect(motion.from != motion.to)
            }
        }
        #expect(KenBurns.motion(imageAspect: 4.0 / 3, screenAspect: 1.6, seed: 1).fills)
        #expect(!KenBurns.motion(imageAspect: 0.75, screenAspect: 1.6, seed: 1).fills, "portrait photos sit whole")
        #expect(KenBurns.motion(imageAspect: 1.5, screenAspect: 1.6, seed: 7) == KenBurns.motion(imageAspect: 1.5, screenAspect: 1.6, seed: 7))
        #expect(KenBurns.seed("abc") == KenBurns.seed("abc") && KenBurns.seed("abc") != KenBurns.seed("abd"))
    }
}

@Suite struct SoundtrackTests {
    @Test func theTuneLoopsCleanly() {
        let rate = 22_050
        let samples = Soundtrack.render(sampleRate: rate)
        let frames = samples.count / 2
        #expect(frames == Int((Soundtrack.loopSeconds * Double(rate)).rounded()))
        let finite = samples.allSatisfy { $0.isFinite }
        #expect(finite)
        let peak = samples.map(abs).max() ?? 0
        #expect(abs(peak - 0.6) < 0.001)
        let rms = sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
        #expect(rms > 0.03 && rms < 0.3, "\(rms)")
        // No click where the loop starts again: the jump is no bigger than between neighbouring samples.
        var largestStep: Float = 0
        for frame in 1..<frames { largestStep = max(largestStep, abs(samples[frame * 2] - samples[(frame - 1) * 2])) }
        #expect(abs(samples[0] - samples[(frames - 1) * 2]) <= largestStep + 0.01)
        #expect(abs(samples[1] - samples[(frames - 1) * 2 + 1]) <= largestStep + 0.01)
    }

    @Test func wavFiles() {
        let data = Soundtrack.wav([0, 0.5, -0.5, 1], sampleRate: 8000)
        func number(_ range: Range<Int>) -> Int {
            data[range].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        }
        #expect(data.count == 44 + 8)
        #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        #expect(data[22] == 2)
        #expect(number(24..<28) == 8000)
        #expect(number(44..<46) == 0)
        #expect(number(50..<52) == 32_767)
    }
}
