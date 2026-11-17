import Foundation

/// The library's items at one moment, with the lookups every view needs worked out once: items by ID and the day
/// each was taken. Immutable, so it can be built off the main thread and handed to views.
public struct LibrarySnapshot: Sendable {
    /// Every item, oldest first.
    public let items: [MediaItem]
    public let timeZone: TimeZone
    private let indexByID: [PhotoID: Int]
    /// The day each item was taken, parallel to `items`.
    private let dayNumbers: [Int]

    public init(items: [MediaItem], timeZone: TimeZone = .current) {
        let sorted = items.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        self.items = sorted
        self.timeZone = timeZone
        var index: [PhotoID: Int] = [:]
        index.reserveCapacity(sorted.count)
        for (position, item) in sorted.enumerated() { index[item.id] = position }
        indexByID = index
        dayNumbers = sorted.map { CivilDay($0.date, in: timeZone).number }
    }

    public static let empty = LibrarySnapshot(items: [])

    public var count: Int { items.count }
    public var allIDs: [PhotoID] { items.map(\.id) }

    public func item(_ id: PhotoID) -> MediaItem? {
        indexByID[id].map { items[$0] }
    }

    public func contains(_ id: PhotoID) -> Bool { indexByID[id] != nil }

    /// The position of an item in date order, used to sort quickly.
    public func position(of id: PhotoID) -> Int? { indexByID[id] }

    public func day(of id: PhotoID) -> CivilDay? {
        indexByID[id].map { CivilDay(number: dayNumbers[$0]) }
    }

    /// How many items were taken on each day, for the calendar's dots.
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

    /// A copy with some items changed (new dates, a favorite) and the order and days worked out again.
    public func updating(_ changed: [MediaItem]) -> LibrarySnapshot {
        guard !changed.isEmpty else { return self }
        var items = self.items
        for item in changed {
            if let index = indexByID[item.id] { items[index] = item }
        }
        return LibrarySnapshot(items: items, timeZone: timeZone)
    }
}
