import Foundation

/// Locale-aware wording for dates and counts. Formatters are made once per template and reused; date formatters
/// are safe to share between threads.
public struct Formatting: Sendable {
    public var locale: Locale
    public var calendar: Calendar

    public init(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) {
        self.locale = locale
        var calendar = calendar
        calendar.locale = locale
        self.calendar = calendar
    }

    public var timeZone: TimeZone { calendar.timeZone }

    /// "Today", "Yesterday", "Saturday, June 14" this year, "Saturday, June 14, 2025" in other years.
    public func dayTitle(_ day: CivilDay, today: CivilDay) -> String {
        if day == today { return "Today" }
        if day == today.adding(days: -1) { return "Yesterday" }
        let template = day.year == today.year ? "EEEEMMMMd" : "EEEEMMMMdy"
        return format(day, template)
    }

    /// "Tuesday, November 17", without the year.
    public func weekdayAndDay(_ day: CivilDay) -> String { format(day, "EEEEMMMMd") }

    /// "June 2025".
    public func monthTitle(year: Int, month: Int) -> String {
        format(CivilDay(year: year, month: month, day: 1), "MMMMy")
    }

    /// "2025".
    public func yearTitle(_ year: Int) -> String {
        format(CivilDay(year: year, month: 1, day: 1), "y")
    }

    /// "Saturday, June 14, 2025".
    public func longDay(_ day: CivilDay) -> String { format(day, "EEEEMMMMdy") }

    /// "Jun 14, 2025 at 3:42 PM".
    public func dateAndTime(_ date: Date) -> String {
        let formatter = Self.cache.formatter(locale: locale, calendar: calendar, key: "medium+short") { formatter in
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }

    /// "3:42 PM".
    public func time(_ date: Date) -> String {
        let formatter = Self.cache.formatter(locale: locale, calendar: calendar, key: "time") { formatter in
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }

    /// "Jun 14, 2025".
    public func mediumDate(_ date: Date) -> String {
        let formatter = Self.cache.formatter(locale: locale, calendar: calendar, key: "medium") { formatter in
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    /// "Jun 14 – 20, 2025", "Jun 14, 2025" for a single day, or nil with no dates.
    public func dateRange(from first: Date?, to last: Date?) -> String? {
        guard let first, let last else { return nil }
        if CivilDay(first, in: timeZone) == CivilDay(last, in: timeZone) { return mediumDate(first) }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: min(first, last), to: max(first, last))
    }

    /// The month names in this locale, January first: full ("June") and short ("Jun").
    public var monthNames: [(full: String, short: String)] {
        (1...12).map { month in
            let day = CivilDay(year: 2001, month: month, day: 1)
            return (format(day, "MMMM"), format(day, "MMM"))
        }
    }

    /// "1 photo", "12 photos and 3 videos", "No photos".
    public func count(photos: Int, videos: Int) -> String {
        let photoText = photos == 1 ? "1 photo" : "\(number(photos)) photos"
        let videoText = videos == 1 ? "1 video" : "\(number(videos)) videos"
        switch (photos, videos) {
        case (0, 0): return "No photos"
        case (_, 0): return photoText
        case (0, _): return videoText
        default: return "\(photoText) and \(videoText)"
        }
    }

    /// "1 item", "1,234 items".
    public func count(items: Int) -> String {
        items == 1 ? "1 item" : "\(number(items)) items"
    }

    /// 1234 → "1,234" in this locale.
    public func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 75 seconds → "1:15"; an hour or more → "1:02:03".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    private func format(_ day: CivilDay, _ template: String) -> String {
        let formatter = Self.cache.formatter(locale: locale, calendar: calendar, template: template)
        // Noon keeps the day the same in every time zone the calendar might use.
        var noon = DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)
        noon.calendar = formatter.calendar
        noon.timeZone = formatter.timeZone
        return formatter.string(from: formatter.calendar.date(from: noon) ?? Date())
    }

    private static let cache = FormatterCache()
}

/// Shared date formatters, keyed by locale, calendar, time zone and template.
final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    func formatter(locale: Locale, calendar: Calendar, template: String) -> DateFormatter {
        formatter(locale: locale, calendar: calendar, key: "t:" + template) { formatter in
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
    }

    func formatter(locale: Locale, calendar: Calendar, key: String, configure: (DateFormatter) -> Void) -> DateFormatter {
        let fullKey = [locale.identifier, "\(calendar.identifier)", calendar.timeZone.identifier, key].joined(separator: "|")
        lock.lock()
        defer { lock.unlock() }
        if let existing = formatters[fullKey] { return existing }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        configure(formatter)
        formatters[fullKey] = formatter
        return formatter
    }
}
