import Foundation

/// A notification about a day's memories, to show at a set time on that day.
public struct MemoryNotification: Hashable, Sendable {
    /// The day it's about.
    public let day: CivilDay
    /// When to show it.
    public let date: Date
    public let title: String
    public let body: String
    /// The photo to show with it.
    public let keyPhoto: PhotoID?
    /// The memory a click opens.
    public let memoryID: String

    /// The identifier the notification goes by, one per day.
    public var identifier: String { "memory-\(day)" }
}

public enum MemoryNotifications {
    /// Notifications for the days from `today` on (for `days` days) that have photos from the same day in earlier
    /// years, each at `hour`:`minute`. Today's is included even if its time has passed; the caller decides whether
    /// to show it at once.
    public static func plan(finder: MemoryFinder, from today: CivilDay, days: Int, hour: Int, minute: Int) -> [MemoryNotification] {
        let calendar = finder.formatting.calendar
        var plan: [MemoryNotification] = []
        for offset in 0..<max(days, 0) {
            let day = today.adding(days: offset)
            let memories = finder.onThisDay(day)
            guard let first = memories.first else { continue }
            let years = finder.photosOnThisDay(day)
            let opening = years.count > 1 ? memories.last ?? first : first
            guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))
            else { continue }
            plan.append(MemoryNotification(day: day, date: date, title: title(years: years, on: day),
                                           body: body(years: years, finder: finder, on: day), keyPhoto: opening.keyPhoto,
                                           memoryID: opening.id))
        }
        return plan
    }

    /// "1 Year Ago Today", "5 Years Ago Today", or "Memories from This Day" for several years.
    static func title(years: [Int: [PhotoID]], on day: CivilDay) -> String {
        guard years.count == 1, let year = years.keys.first else { return "Memories from This Day" }
        let ago = day.year - year
        return ago == 1 ? "1 Year Ago Today" : "\(ago) Years Ago Today"
    }

    /// "12 photos from Thursday, July 4, 2019. Click to watch them as a slideshow."
    static func body(years: [Int: [PhotoID]], finder: MemoryFinder, on day: CivilDay) -> String {
        let snapshot = finder.arranger.snapshot
        if years.count == 1, let (year, ids) = years.first {
            let counts = snapshot.counts(of: ids)
            let photoDay = ids.first.flatMap(snapshot.day(of:)) ?? CivilDay(year: year, month: day.month, day: day.day)
            let what = finder.formatting.count(photos: counts.photos, videos: counts.videos)
            let them = ids.count == 1 ? "it" : "them"
            let wrote = finder.arranger.catalog.entry(for: photoDay) != nil ? ", and what you wrote that day" : ""
            return "\(what) from \(finder.formatting.longDay(photoDay))\(wrote). Click to watch \(them) as a slideshow."
        }
        let list = ListFormatter.localizedString(byJoining: years.keys.sorted().map(String.init))
        return "Photos from this day in \(list). Click to watch them as a slideshow."
    }
}
