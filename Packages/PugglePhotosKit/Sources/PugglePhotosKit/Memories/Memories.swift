import Foundation

/// A set of photos worth looking back on, ready to play as a slideshow: this day in past years, a big day or a
/// trip, a year, a label's best photos, an album or photos picked by hand.
public struct Memory: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Photos from this calendar day, `yearsAgo` years back.
        case onThisDay(yearsAgo: Int)
        /// Photos from this calendar day in every earlier year.
        case onThisDayEveryYear
        /// Photos from the days around this one, `yearsAgo` years back, when that year has none on the day itself.
        case thisWeek(yearsAgo: Int)
        /// The person's favorites.
        case favorites
        /// Photos from the days the person wrote about in the journal.
        case journal
        /// A day, or a few days in a row, with lots of photos.
        case event
        case year(Int)
        case label(UUID)
        case album(UUID)
        case selection
    }

    /// Stable across launches, so a notification or a menu can name a memory: "onthisday-2026-11-17-1",
    /// "event-2025-06-14", "year-2025", "label-…".
    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String
    /// The photos, in the order they play: by date, with the best kept and near-duplicates dropped.
    public let items: [PhotoID]
    /// The photo on its card.
    public let keyPhoto: PhotoID?
    public let firstDate: Date
    public let lastDate: Date
    /// What the journal says about the memory's day, for memories of a single day.
    public let note: String

    public init(id: String, kind: Kind, title: String, subtitle: String, items: [PhotoID], keyPhoto: PhotoID?,
                firstDate: Date, lastDate: Date, note: String = "") {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.keyPhoto = keyPhoto
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.note = note
    }
}

/// Everything the Memories page shows.
public struct MemoriesPage: Sendable {
    /// This day in past years, the most recent year first, then every year together.
    public var onThisDay: [Memory] = []
    /// Big days and trips, the most recent first.
    public var highlights: [Memory] = []
    /// Favorites, and the days written about in the journal.
    public var collections: [Memory] = []
    /// A memory for each year with enough photos, the most recent first.
    public var years: [Memory] = []
    /// The best photos with each label that has enough of them.
    public var labels: [Memory] = []

    public init(onThisDay: [Memory] = [], highlights: [Memory] = [], collections: [Memory] = [], years: [Memory] = [],
                labels: [Memory] = []) {
        self.onThisDay = onThisDay
        self.highlights = highlights
        self.collections = collections
        self.years = years
        self.labels = labels
    }

    public var all: [Memory] { onThisDay + highlights + collections + years + labels }
    public var isEmpty: Bool { all.isEmpty }
    public func memory(_ id: String) -> Memory? { all.first { $0.id == id } }
}

/// Finds memories in the library. Screenshots are never memories.
public struct MemoryFinder: Sendable {
    public let arranger: Arranger
    public let formatting: Formatting
    public let today: CivilDay
    /// The most photos a memory plays.
    public var limit = 40
    /// Photos by calendar day (month × 100 + day), then by year: worked out once.
    private let byMonthDay: [Int: [Int: [PhotoID]]]
    private let byDay: [CivilDay: [PhotoID]]

    public init(arranger: Arranger, formatting: Formatting, today: CivilDay) {
        self.arranger = arranger
        self.formatting = formatting
        self.today = today
        var byMonthDay: [Int: [Int: [PhotoID]]] = [:]
        var byDay: [CivilDay: [PhotoID]] = [:]
        for item in arranger.snapshot.items where item.kind != .screenshot {
            guard let day = arranger.snapshot.day(of: item.id) else { continue }
            byMonthDay[day.month * 100 + day.day, default: [:]][day.year, default: []].append(item.id)
            byDay[day, default: []].append(item.id)
        }
        self.byMonthDay = byMonthDay
        self.byDay = byDay
    }

    private var snapshot: LibrarySnapshot { arranger.snapshot }
    private var catalog: Catalog { arranger.catalog }

    public func page() -> MemoriesPage {
        MemoriesPage(onThisDay: onThisDay() + thisWeek(), highlights: highlights(), collections: [favorites(), journal()].compactMap { $0 },
                     years: years(), labels: labels())
    }

    /// A memory by its ID, found again (for a notification that was clicked, or a card).
    public func memory(_ id: String) -> Memory? {
        if id.hasPrefix("day-") {
            return CivilDay(String(id.dropFirst(4))).flatMap(day)
        }
        for prefix in ["onthisday-", "thisweek-"] where id.hasPrefix(prefix) {
            let parts = id.dropFirst(prefix.count).split(separator: "-").compactMap { Int($0) }
            guard parts.count >= 3 else { return nil }
            let day = CivilDay(year: parts[0], month: parts[1], day: parts[2])
            return (prefix == "onthisday-" ? onThisDay(day) : thisWeek(day)).first { $0.id == id }
        }
        return page().memory(id)
    }

    // MARK: On this day

    /// Photos taken on `day`'s date in earlier years. On February 28 in a year without a 29th, photos from
    /// February 29 count too.
    public func photosOnThisDay(_ day: CivilDay) -> [Int: [PhotoID]] {
        var years = byMonthDay[day.month * 100 + day.day] ?? [:]
        if day.month == 2, day.day == 28, CivilDay.daysIn(year: day.year, month: 2) == 28 {
            for (year, ids) in byMonthDay[229] ?? [:] { years[year, default: []] += ids }
        }
        return years.filter { $0.key < day.year && !$0.value.isEmpty }
    }

    /// One memory for each earlier year with photos on this day, the most recent first, then one with every year
    /// when there's more than one.
    public func onThisDay(_ day: CivilDay? = nil) -> [Memory] {
        let day = day ?? today
        let years = photosOnThisDay(day)
        guard !years.isEmpty else { return [] }
        var memories: [Memory] = []
        for year in years.keys.sorted(by: >) {
            let ids = years[year]!
            let yearsAgo = day.year - year
            let title = yearsAgo == 1 ? "1 Year Ago Today" : "\(yearsAgo) Years Ago Today"
            let photoDay = CivilDay(year: year, month: day.month, day: min(day.day, CivilDay.daysIn(year: year, month: day.month)))
            let originalDay = ids.first.flatMap(snapshot.day(of:)) ?? photoDay
            if let memory = make("onthisday-\(day)-\(yearsAgo)", .onThisDay(yearsAgo: yearsAgo), title: title,
                                 subtitle: formatting.longDay(originalDay), ids: ids, note: catalog.entry(for: originalDay)?.text ?? "") {
                memories.append(memory)
            }
        }
        if years.count > 1 {
            let ids = years.keys.sorted().flatMap { years[$0]! }
            let list = ListFormatter.localizedString(byJoining: years.keys.sorted().map(String.init))
            if let memory = make("onthisday-\(day)-all", .onThisDayEveryYear, title: "This Day Through the Years",
                                 subtitle: list, ids: ids) {
                memories.append(memory)
            }
        }
        return memories
    }

    /// For earlier years with no photos on this very day, the photos from the three days either side of it, when
    /// there are at least four. The most recent year first.
    public func thisWeek(_ day: CivilDay? = nil, minimum: Int = 4) -> [Memory] {
        let day = day ?? today
        let exact = Set(photosOnThisDay(day).keys)
        let years = Set(byDay.keys.map(\.year)).filter { $0 < day.year && !exact.contains($0) }.sorted(by: >)
        return years.compactMap { year in
            let middle = CivilDay(year: year, month: day.month, day: min(day.day, CivilDay.daysIn(year: year, month: day.month)))
            let days = (-3...3).map { middle.adding(days: $0) }.filter { byDay[$0] != nil }
            let ids = days.flatMap { byDay[$0] ?? [] }
            guard ids.count >= minimum, let first = days.first, let last = days.last else { return nil }
            let yearsAgo = day.year - year
            let title = yearsAgo == 1 ? "This Week, 1 Year Ago" : "This Week, \(yearsAgo) Years Ago"
            let dates = first == last ? formatting.longDay(first)
                : (formatting.dateRange(from: first.start(in: formatting.calendar), to: last.start(in: formatting.calendar)) ?? "")
            return make("thisweek-\(day)-\(yearsAgo)", .thisWeek(yearsAgo: yearsAgo), title: title, subtitle: dates, ids: ids)
        }
    }

    // MARK: Favorites and the journal

    /// The person's favorite photos, when there are at least `minimum`.
    public func favorites(minimum: Int = 6) -> Memory? {
        let ids = snapshot.items.filter { $0.isFavorite && $0.kind != .screenshot }.map(\.id)
        guard ids.count >= minimum else { return nil }
        let counts = snapshot.counts(of: ids)
        return make("favorites", .favorites, title: "Your Favorites", subtitle: formatting.count(photos: counts.photos, videos: counts.videos), ids: ids)
    }

    /// Photos from the days the journal talks about, when there are at least two such days.
    public func journal(minimum: Int = 2) -> Memory? {
        let days = catalog.journalDays.filter { byDay[$0] != nil }
        guard days.count >= minimum else { return nil }
        let ids = days.sorted().flatMap { byDay[$0] ?? [] }
        return make("journal", .journal, title: "Days You Wrote About", subtitle: days.count == 1 ? "1 day" : "\(days.count) days", ids: ids)
    }

    /// One day's photos, with what the journal says about it: a day played from the journal.
    public func day(_ day: CivilDay) -> Memory? {
        let ids = byDay[day] ?? []
        let counts = snapshot.counts(of: ids)
        return make("day-\(day)", .event, title: formatting.longDay(day), subtitle: formatting.count(photos: counts.photos, videos: counts.videos),
                    ids: ids, note: catalog.entry(for: day)?.text ?? "")
    }

    // MARK: Big days and trips

    /// Days with at least `minimum` photos, with neighboring such days joined into one trip of at most a week.
    /// Named for the album or label most of their photos share, or for a holiday, or else for their dates. The most
    /// recent first.
    public func highlights(minimum: Int = 8, count: Int = 18) -> [Memory] {
        let busyDays = byDay.filter { $0.value.count >= minimum }.keys.sorted()
        var runs: [[CivilDay]] = []
        for day in busyDays {
            if let run = runs.last, let last = run.last, day.number - last.number == 1, run.count < 7 {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }
        var memories: [Memory] = []
        for run in runs.reversed() {
            guard let first = run.first, let last = run.last else { continue }
            let ids = run.flatMap { byDay[$0] ?? [] }
            let title = eventTitle(ids, first: first, last: last)
            let dates = first == last ? formatting.longDay(first)
                : (formatting.dateRange(from: first.start(in: formatting.calendar), to: last.start(in: formatting.calendar)) ?? "")
            let counts = snapshot.counts(of: ids)
            let subtitle = title.dated ? formatting.count(photos: counts.photos, videos: counts.videos) : dates
            if let memory = make("event-\(first)", .event, title: title.text, subtitle: subtitle, ids: ids,
                                 note: first == last ? catalog.entry(for: first)?.text ?? "" : "") {
                memories.append(memory)
            }
            if memories.count == count { break }
        }
        return memories
    }

    /// A trip's name, and whether that name is its dates.
    private func eventTitle(_ ids: [PhotoID], first: CivilDay, last: CivilDay) -> (text: String, dated: Bool) {
        var albumCounts: [UUID: Int] = [:]
        var labelCounts: [UUID: Int] = [:]
        for id in ids {
            for album in arranger.membership.albums(containing: id) { albumCounts[album, default: 0] += 1 }
            for label in catalog.photos[id]?.labels ?? [] { labelCounts[label, default: 0] += 1 }
        }
        let half = (ids.count + 1) / 2
        // The smallest album that holds most of the photos names the event best.
        if let album = albumCounts.filter({ $0.value >= half }).min(by: { lhs, rhs in
            let (a, b) = (catalog.album(lhs.key)?.items.count ?? 0, catalog.album(rhs.key)?.items.count ?? 0)
            return a == b ? lhs.value > rhs.value : a < b
        }), let title = catalog.album(album.key)?.title {
            return ("\(title), \(first.year)", false)
        }
        if let holiday = Self.holiday(first) ?? (first == last ? nil : Self.holiday(last)) {
            return ("\(holiday) \(first.year)", false)
        }
        if let label = labelCounts.filter({ $0.value >= half }).max(by: { $0.value < $1.value }),
           let name = catalog.label(label.key)?.name {
            return ("\(name), \(formatting.monthTitle(year: first.year, month: first.month))", false)
        }
        if first == last { return (formatting.longDay(first), true) }
        return (formatting.dateRange(from: first.start(in: formatting.calendar), to: last.start(in: formatting.calendar)) ?? "", true)
    }

    /// Days that are holidays wherever the calendar is used this way.
    static func holiday(_ day: CivilDay) -> String? {
        switch (day.month, day.day) {
        case (12, 24): "Christmas Eve"
        case (12, 25): "Christmas"
        case (12, 31): "New Year’s Eve"
        case (1, 1): "New Year’s Day"
        case (2, 14): "Valentine’s Day"
        case (10, 31): "Halloween"
        default: nil
        }
    }

    // MARK: Years and labels

    /// A memory for each year with at least `minimum` photos, the most recent first; this year only once it's over.
    public func years(minimum: Int = 20) -> [Memory] {
        var byYear: [Int: [PhotoID]] = [:]
        for (day, ids) in byDay { byYear[day.year, default: []] += ids }
        return byYear.filter { $0.key < today.year && $0.value.count >= minimum }.keys.sorted(by: >).compactMap { year in
            let ids = byYear[year]!.sorted { (snapshot.position(of: $0) ?? 0) < (snapshot.position(of: $1) ?? 0) }
            let counts = snapshot.counts(of: ids)
            return make("year-\(year)", .year(year), title: "\(formatting.yearTitle(year)) in Photos",
                        subtitle: formatting.count(photos: counts.photos, videos: counts.videos), ids: ids)
        }
    }

    /// The best photos with each label that has at least `minimum`.
    public func labels(minimum: Int = 6) -> [Memory] {
        catalog.labels.compactMap { label in
            let ids = arranger.ids(for: .label(label.id)).filter { snapshot.item($0)?.kind != .screenshot }
            guard ids.count >= minimum else { return nil }
            let counts = snapshot.counts(of: ids)
            return make("label-\(label.id.uuidString)", .label(label.id), title: label.displayName,
                        subtitle: formatting.count(photos: counts.photos, videos: counts.videos), ids: ids)
        }
    }

    // MARK: Slideshows of albums and picked photos

    /// An album as a slideshow, in the album's order, every photo included.
    public func album(_ id: UUID) -> Memory? {
        guard let album = catalog.album(id) else { return nil }
        var ids = album.items.filter(snapshot.contains)
        switch album.order {
        case .custom: break
        case .oldestFirst: ids = arranger.sorted(ids, by: .dateTaken, ascending: true)
        case .newestFirst: ids = arranger.sorted(ids, by: .dateTaken, ascending: false)
        }
        let summary = arranger.summary(of: album)
        let subtitle = formatting.dateRange(from: summary.firstDate, to: summary.lastDate) ?? ""
        return make("album-\(id.uuidString)", .album(id), title: album.title, subtitle: subtitle, ids: ids, curate: false,
                    key: arranger.cover(of: album))
    }

    /// Photos picked by hand, played in the order given.
    public func selection(_ ids: [PhotoID], title: String) -> Memory? {
        let present = ids.filter(snapshot.contains)
        let dates = present.compactMap { snapshot.item($0)?.date }
        return make("selection", .selection, title: title, subtitle: formatting.dateRange(from: dates.min(), to: dates.max()) ?? "",
                    ids: present, curate: false)
    }

    // MARK: Making memories

    private func make(_ id: String, _ kind: Memory.Kind, title: String, subtitle: String, ids: [PhotoID],
                      curate: Bool = true, key: PhotoID? = nil, note: String = "") -> Memory? {
        let items = curate ? Curator(arranger: arranger).pick(ids, limit: limit) : ids
        guard !items.isEmpty else { return nil }
        let dates = items.compactMap { snapshot.item($0)?.date }
        return Memory(id: id, kind: kind, title: title, subtitle: subtitle, items: items,
                      keyPhoto: key ?? Curator(arranger: arranger).keyPhoto(items),
                      firstDate: dates.min() ?? .distantPast, lastDate: dates.max() ?? .distantPast, note: note)
    }
}

/// Picks the photos a memory plays: no screenshots, one of each burst of near-identical shots, and when there are too
/// many, the favorites and the photos with captions, notes and labels, plus others spread across the time.
public struct Curator: Sendable {
    public let arranger: Arranger

    public init(arranger: Arranger) { self.arranger = arranger }

    /// How much a photo deserves a place: favorites most, then captions, notes and labels.
    public func score(_ id: PhotoID) -> Double {
        guard let item = arranger.snapshot.item(id) else { return 0 }
        let details = arranger.catalog.photos[id]
        var score = 0.0
        if item.isFavorite { score += 5 }
        if !(details?.caption.isEmpty ?? true) { score += 3 }
        if !(details?.note.isEmpty ?? true) { score += 2 }
        score += Double(min(details?.labels.count ?? 0, 2))
        if item.kind.isVideo { score += 1 }
        if item.kind == .livePhoto { score += 0.5 }
        return score
    }

    /// At most `limit` photos, in date order: the best half by score, then the rest spread evenly across the
    /// photos' time, so a year shows every season rather than one busy weekend.
    public func pick(_ ids: [PhotoID], limit: Int) -> [PhotoID] {
        let snapshot = arranger.snapshot
        let ordered = ids.filter { snapshot.item($0).map { $0.kind != .screenshot } ?? false }
            .sorted { (snapshot.position(of: $0) ?? 0) < (snapshot.position(of: $1) ?? 0) }
        // One photo from each burst: a run of shots, each within three seconds of the one before.
        var kept: [PhotoID] = []
        var previous: Date?
        for id in ordered {
            let date = snapshot.item(id)?.date
            defer { previous = date }
            if let last = kept.last, let previous, let date, date.timeIntervalSince(previous) < 3 {
                if score(id) > score(last) { kept[kept.count - 1] = id }
                continue
            }
            kept.append(id)
        }
        guard kept.count > limit else { return kept }
        // The best half by score, then the rest spread evenly over what's left.
        let best = kept.enumerated().filter { score($0.element) > 0 }
            .sorted { score($0.element) == score($1.element) ? $0.offset < $1.offset : score($0.element) > score($1.element) }
            .prefix(limit / 2).map(\.offset)
        var chosen = Set(best)
        let remaining = kept.indices.filter { !chosen.contains($0) }
        let wanted = limit - chosen.count
        if wanted > 0, !remaining.isEmpty {
            let step = Double(remaining.count) / Double(wanted)
            for index in 0..<wanted {
                chosen.insert(remaining[min(remaining.count - 1, Int(Double(index) * step + step / 2))])
            }
        }
        return chosen.sorted().map { kept[$0] }
    }

    /// The photo for a memory's card: the best scored, else the one in the middle.
    public func keyPhoto(_ ids: [PhotoID]) -> PhotoID? {
        guard !ids.isEmpty else { return nil }
        let photos = ids.filter { !(arranger.snapshot.item($0)?.kind.isVideo ?? true) }
        let pool = photos.isEmpty ? ids : photos
        let best = pool.max { score($0) == score($1) ? false : score($0) < score($1) }
        if let best, score(best) > 0 { return best }
        return pool[pool.count / 2]
    }
}
