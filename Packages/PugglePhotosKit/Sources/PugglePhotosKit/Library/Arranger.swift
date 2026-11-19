import Foundation

/// The places in the sidebar that show photos.
public enum LibrarySource: Hashable, Codable, Sendable {
    /// The Memories page, rather than photos.
    case memories
    /// One memory's photos.
    case memory(String)
    /// The journal, rather than photos.
    case journal
    case library
    case favorites
    case videos
    case recentlyAdded
    /// The covers of every album, rather than photos.
    case allAlbums
    case album(UUID)
    case label(UUID)
    /// An album someone shared with you, to look at.
    case sharedAlbum(UUID)
}

/// How photos are grouped into sections.
public enum Grouping: String, Codable, Sendable, CaseIterable {
    case none, day, month, year, album, label

    public var displayName: String {
        switch self {
        case .none: "None"
        case .day: "Day"
        case .month: "Month"
        case .year: "Year"
        case .album: "Album"
        case .label: "Label"
        }
    }

    public var isByDate: Bool { self == .day || self == .month || self == .year }
}

/// What photos are sorted by.
public enum SortKey: String, Codable, Sendable, CaseIterable {
    case dateTaken, dateAdded, title, kind
    /// An album's own order, which photos can be dragged around in.
    case custom

    public var displayName: String {
        switch self {
        case .dateTaken: "Date Taken"
        case .dateAdded: "Date Added"
        case .title: "Title"
        case .kind: "Kind"
        case .custom: "Album Order"
        }
    }
}

/// How one place in the sidebar shows its photos.
public struct Arrangement: Codable, Hashable, Sendable {
    public var grouping: Grouping
    public var sort: SortKey
    public var ascending: Bool

    public init(grouping: Grouping = .day, sort: SortKey = .dateTaken, ascending: Bool = true) {
        self.grouping = grouping
        self.sort = sort
        self.ascending = ascending
    }

    /// The library's timeline: days, oldest first, the newest photos at the bottom.
    public static let timeline = Arrangement()

    /// When photos are in date order, dropping some between two others moves them to that moment.
    public var isDateOrdered: Bool { sort == .dateTaken && grouping != .album && grouping != .label }
}

/// A run of photos under one heading.
public struct PhotoSection: Hashable, Identifiable, Sendable {
    public enum Key: Hashable, Sendable {
        case all
        case day(CivilDay)
        case month(year: Int, month: Int)
        case year(Int)
        case album(UUID)
        case noAlbum
        case label(UUID)
        case noLabel

        /// The first and last day the section covers, for date sections.
        public var days: ClosedRange<CivilDay>? {
            switch self {
            case let .day(day): return day...day
            case let .month(year, month):
                return CivilDay(year: year, month: month, day: 1)...CivilDay(year: year, month: month,
                                                                              day: CivilDay.daysIn(year: year, month: month))
            case let .year(year): return CivilDay(year: year, month: 1, day: 1)...CivilDay(year: year, month: 12, day: 31)
            default: return nil
            }
        }
    }

    public let key: Key
    public var items: [PhotoID]
    public var id: Key { key }

    public init(key: Key, items: [PhotoID]) {
        self.key = key
        self.items = items
    }
}

/// An album as the album covers show it.
public struct AlbumSummary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let photos: Int
    public let videos: Int
    public let firstDate: Date?
    public let lastDate: Date?
    public let created: Date
    public let cover: PhotoID?

    public var count: Int { photos + videos }
}

/// How album covers are sorted.
public enum AlbumSort: String, Codable, Sendable, CaseIterable {
    case name, date, created, count

    public var displayName: String {
        switch self {
        case .name: "Name"
        case .date: "Date"
        case .created: "Date Created"
        case .count: "Number of Items"
        }
    }
}

/// Picks, sorts and groups the photos a view shows.
public struct Arranger: Sendable {
    public let snapshot: LibrarySnapshot
    public let catalog: Catalog
    public let membership: Membership
    /// The albums shared with you, whose photos the snapshot holds as extras.
    public let sharedAlbums: [SharedAlbum]

    public init(snapshot: LibrarySnapshot, catalog: Catalog, membership: Membership? = nil, sharedAlbums: [SharedAlbum] = []) {
        self.snapshot = snapshot
        self.catalog = catalog
        self.membership = membership ?? Membership(catalog)
        self.sharedAlbums = sharedAlbums
    }

    // MARK: Which photos

    /// The photos a place in the sidebar holds, in date order (an album in its own order). `recent` comes from the
    /// library when it keeps that list itself; `memory` is the photos of the memory shown.
    public func ids(for source: LibrarySource, recent: [PhotoID] = [], memory: [PhotoID] = []) -> [PhotoID] {
        switch source {
        case .memories, .journal:
            return []
        case .memory:
            return memory.filter(snapshot.contains)
        case .library:
            return snapshot.allIDs
        case .favorites:
            return snapshot.items.filter(\.isFavorite).map(\.id)
        case .videos:
            return snapshot.items.filter(\.kind.isVideo).map(\.id)
        case .recentlyAdded:
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            let added = snapshot.items.filter { ($0.addedDate ?? .distantPast) >= cutoff }
            if !added.isEmpty {
                return added.sorted { ($0.addedDate ?? $0.date) < ($1.addedDate ?? $1.date) }.map(\.id)
            }
            return recent.filter(snapshot.contains)
        case .allAlbums:
            return []
        case let .album(id):
            return (catalog.album(id)?.items ?? []).filter(snapshot.contains)
        case let .label(id):
            return membership.photos(labeled: id).filter(snapshot.contains)
                .sorted { (snapshot.position(of: $0) ?? 0) < (snapshot.position(of: $1) ?? 0) }
        case let .sharedAlbum(id):
            return (sharedAlbums.first { $0.id == id }?.photoIDs ?? []).filter(snapshot.contains)
        }
    }

    // MARK: Sorting

    /// Sorts photos. `custom` keeps the order given (an album's order), reversed when descending.
    public func sorted(_ ids: [PhotoID], by sort: SortKey, ascending: Bool) -> [PhotoID] {
        let position = { (id: PhotoID) in snapshot.position(of: id) ?? Int.max }
        var result: [PhotoID]
        switch sort {
        case .custom:
            result = ids
        case .dateTaken:
            result = ids.sorted { position($0) < position($1) }
        case .dateAdded:
            let keys = Dictionary(ids.map { ($0, snapshot.item($0).map { $0.addedDate ?? $0.date } ?? .distantPast) },
                                  uniquingKeysWith: { first, _ in first })
            result = ids.sorted { lhs, rhs in
                let (a, b) = (keys[lhs]!, keys[rhs]!)
                return a == b ? position(lhs) < position(rhs) : a < b
            }
        case .title:
            // Photos with a title come first, by title; the rest follow in date order.
            let keys = Dictionary(ids.map { ($0, Self.collationKey(title(of: $0))) }, uniquingKeysWith: { first, _ in first })
            result = ids.sorted { lhs, rhs in
                let (a, b) = (keys[lhs]!, keys[rhs]!)
                if a.isEmpty != b.isEmpty { return !a.isEmpty }
                return a == b ? position(lhs) < position(rhs) : a < b
            }
        case .kind:
            let rank = { (id: PhotoID) in snapshot.item(id)?.kind.sortRank ?? 0 }
            result = ids.sorted { lhs, rhs in
                let (a, b) = (rank(lhs), rank(rhs))
                return a == b ? position(lhs) < position(rhs) : a < b
            }
        }
        if !ascending {
            if sort == .title {
                // Untitled photos stay at the end either way.
                let titled = result.prefix { !title(of: $0).isEmpty }
                return titled.reversed() + result.dropFirst(titled.count)
            }
            result.reverse()
        }
        return result
    }

    /// The caption, else the file name, else nothing.
    public func title(of id: PhotoID) -> String {
        let caption = SharedAlbum.isShared(id) ? (sharedAlbums.lazy.compactMap { $0.item(id) }.first?.caption ?? "") : (catalog.photos[id]?.caption ?? "")
        if !caption.isEmpty { return caption }
        return snapshot.item(id)?.fileName ?? ""
    }

    /// A key that sorts by plain comparison the way people expect: ignoring case and accents, with numbers in
    /// numeric order ("IMG_9" before "IMG_10").
    static func collationKey(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var key = ""
        key.reserveCapacity(folded.count + 8)
        var digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            let trimmed = String(digits.drop { $0 == "0" })
            key += String(repeating: "0", count: max(0, 12 - trimmed.count)) + trimmed
            digits = ""
        }
        for character in folded {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else {
                flush()
                key.append(character)
            }
        }
        flush()
        return key
    }

    // MARK: Grouping

    /// Groups sorted photos into sections. Date sections run in the sort's direction (oldest first when ascending);
    /// album and label sections follow the sidebar's order and end with the photos in none. A photo in two albums
    /// shows in both.
    public func sections(_ ids: [PhotoID], arrangement: Arrangement, albumOrder: [UUID]? = nil) -> [PhotoSection] {
        switch arrangement.grouping {
        case .none:
            return ids.isEmpty ? [] : [PhotoSection(key: .all, items: ids)]
        case .day, .month, .year:
            var order: [PhotoSection.Key] = []
            var groups: [PhotoSection.Key: [PhotoID]] = [:]
            for id in ids {
                guard let day = snapshot.day(of: id) else { continue }
                let key: PhotoSection.Key = switch arrangement.grouping {
                case .day: .day(day)
                case .month: .month(year: day.year, month: day.month)
                default: .year(day.year)
                }
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(id)
            }
            let sortedKeys = order.sorted { lhs, rhs in
                let (a, b) = (lhs.days!.lowerBound, rhs.days!.lowerBound)
                return arrangement.ascending ? a < b : a > b
            }
            return sortedKeys.map { PhotoSection(key: $0, items: groups[$0]!) }
        case .album:
            var groups: [UUID: [PhotoID]] = [:]
            var loose: [PhotoID] = []
            for id in ids {
                let albums = membership.albums(containing: id)
                if albums.isEmpty { loose.append(id) }
                for album in albums { groups[album, default: []].append(id) }
            }
            let order = albumOrder ?? catalog.albums.map(\.id)
            var sections = order.compactMap { id in groups[id].map { PhotoSection(key: .album(id), items: $0) } }
            if !loose.isEmpty { sections.append(PhotoSection(key: .noAlbum, items: loose)) }
            return sections
        case .label:
            var groups: [UUID: [PhotoID]] = [:]
            var loose: [PhotoID] = []
            for id in ids {
                let labels = catalog.photos[id]?.labels ?? []
                if labels.isEmpty { loose.append(id) }
                for label in labels { groups[label, default: []].append(id) }
            }
            var sections = catalog.labels.compactMap { label in groups[label.id].map { PhotoSection(key: .label(label.id), items: $0) } }
            if !loose.isEmpty { sections.append(PhotoSection(key: .noLabel, items: loose)) }
            return sections
        }
    }

    /// The heading of a section.
    public func title(of key: PhotoSection.Key, formatting: Formatting, today: CivilDay) -> String {
        switch key {
        case .all: ""
        case let .day(day): formatting.dayTitle(day, today: today)
        case let .month(year, month): formatting.monthTitle(year: year, month: month)
        case let .year(year): formatting.yearTitle(year)
        case let .album(id): catalog.album(id)?.title ?? "Album"
        case .noAlbum: "Not in an Album"
        case let .label(id): catalog.label(id)?.displayName ?? "Label"
        case .noLabel: "No Label"
        }
    }

    // MARK: Albums

    /// The photo an album shows on its cover: the chosen one, else the first in the album's order.
    public func cover(of album: Album) -> PhotoID? {
        if let cover = album.cover, snapshot.contains(cover), album.items.contains(cover) { return cover }
        let present = album.items.filter(snapshot.contains)
        switch album.order {
        case .custom: return present.first
        case .oldestFirst, .newestFirst:
            return present.min { (snapshot.position(of: $0) ?? 0) < (snapshot.position(of: $1) ?? 0) }
        }
    }

    public func summary(of album: Album) -> AlbumSummary {
        var photos = 0, videos = 0
        var first: Date?, last: Date?
        for id in album.items {
            guard let item = snapshot.item(id) else { continue }
            if item.kind.isVideo { videos += 1 } else { photos += 1 }
            if first == nil || item.date < first! { first = item.date }
            if last == nil || item.date > last! { last = item.date }
        }
        return AlbumSummary(id: album.id, title: album.title, photos: photos, videos: videos, firstDate: first,
                            lastDate: last, created: album.created, cover: cover(of: album))
    }

    /// Every album, sorted. Albums sort by the date of their earliest photo; empty ones by when they were made.
    public func albumSummaries(sort: AlbumSort, ascending: Bool) -> [AlbumSummary] {
        let summaries = catalog.albums.map(summary(of:))
        let sorted = summaries.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            let order: ComparisonResult = switch sort {
            case .name: a.title.localizedStandardCompare(b.title)
            case .date: Self.compare(a.firstDate ?? a.created, b.firstDate ?? b.created)
            case .created: Self.compare(a.created, b.created)
            case .count: Self.compare(a.count, b.count)
            }
            if order == .orderedSame { return lhs.offset < rhs.offset }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return sorted.map(\.element)
    }

    static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
