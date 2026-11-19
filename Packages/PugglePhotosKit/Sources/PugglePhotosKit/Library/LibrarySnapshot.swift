import Foundation

/// The library's items at one moment, with the lookups every view needs worked out once: items by ID and the day
/// each was taken. Immutable, so it can be built off the main thread and handed to views.
///
/// It can also hold `extras`: photos from outside the library (those in albums shared with you), which are only
/// looked up. They're found by ID, and sorted and grouped by day with the rest, but they're never among the library's
/// own items, so the library, its days, its counts and everything made from them leave them out.
public struct LibrarySnapshot: Sendable {
    /// Every item in the library, oldest first.
    public let items: [MediaItem]
    /// Photos from outside the library, oldest first.
    public let extras: [MediaItem]
    public let timeZone: TimeZone
    /// Where each item is: below `items.count` in `items`, from there on in `extras`.
    private let indexByID: [PhotoID: Int]
    /// The day each library item was taken, parallel to `items`.
    private let dayNumbers: [Int]
    /// The day each extra was taken, parallel to `extras`.
    private let extraDayNumbers: [Int]

    public init(items: [MediaItem], extras: [MediaItem] = [], timeZone: TimeZone = .current) {
        let order = { (a: MediaItem, b: MediaItem) in a.date == b.date ? a.id < b.id : a.date < b.date }
        let sorted = items.sorted(by: order)
        let outside = extras.sorted(by: order)
        self.items = sorted
        self.extras = outside
        self.timeZone = timeZone
        var index: [PhotoID: Int] = [:]
        index.reserveCapacity(sorted.count + outside.count)
        for (position, item) in sorted.enumerated() { index[item.id] = position }
        for (position, item) in outside.enumerated() where index[item.id] == nil { index[item.id] = sorted.count + position }
        indexByID = index
        dayNumbers = sorted.map { CivilDay($0.date, in: timeZone).number }
        extraDayNumbers = outside.map { CivilDay($0.date, in: timeZone).number }
    }

    public static let empty = LibrarySnapshot(items: [])

    public var count: Int { items.count }
    public var allIDs: [PhotoID] { items.map(\.id) }

    public func item(_ id: PhotoID) -> MediaItem? {
        indexByID[id].map { $0 < items.count ? items[$0] : extras[$0 - items.count] }
    }

    public func contains(_ id: PhotoID) -> Bool { indexByID[id] != nil }

    /// Whether an item is in the library itself, rather than among the extras.
    public func inLibrary(_ id: PhotoID) -> Bool { indexByID[id].map { $0 < items.count } ?? false }

    /// The position of an item in date order, used to sort quickly (the extras come after the library's items).
    public func position(of id: PhotoID) -> Int? { indexByID[id] }

    public func day(of id: PhotoID) -> CivilDay? {
        indexByID[id].map { CivilDay(number: $0 < items.count ? dayNumbers[$0] : extraDayNumbers[$0 - items.count]) }
    }

    /// The library's items taken on a day, oldest first. The days run in order with the items, so halving finds them.
    public func ids(on day: CivilDay) -> [PhotoID] {
        let target = day.number
        var low = 0, high = dayNumbers.count
        while low < high {
            let middle = (low + high) / 2
            if dayNumbers[middle] < target { low = middle + 1 } else { high = middle }
        }
        var ids: [PhotoID] = []
        while low < dayNumbers.count, dayNumbers[low] == target {
            ids.append(items[low].id)
            low += 1
        }
        return ids
    }

    /// How many of the library's items were taken on each day, for the calendar's dots.
    public func countsByDay() -> [CivilDay: Int] {
        var counts: [CivilDay: Int] = [:]
        for number in dayNumbers { counts[CivilDay(number: number), default: 0] += 1 }
        return counts
    }

    /// The photos and videos among some items.
    public func counts(of ids: some Sequence<PhotoID>) -> (photos: Int, videos: Int) {
        var photos = 0, videos = 0
        for id in ids {
            guard let item = item(id) else { continue }
            if item.kind.isVideo { videos += 1 } else { photos += 1 }
        }
        return (photos, videos)
    }

    /// A copy with some library items changed (new dates, a favorite) and the order and days worked out again.
    public func updating(_ changed: [MediaItem]) -> LibrarySnapshot {
        guard !changed.isEmpty else { return self }
        var items = self.items
        for item in changed {
            if let index = indexByID[item.id], index < items.count { items[index] = item }
        }
        return LibrarySnapshot(items: items, extras: extras, timeZone: timeZone)
    }

    /// A copy with other extras: the photos of the albums shared with you, as they are now.
    public func replacingExtras(_ extras: [MediaItem]) -> LibrarySnapshot {
        LibrarySnapshot(items: items, extras: extras, timeZone: timeZone)
    }
}
