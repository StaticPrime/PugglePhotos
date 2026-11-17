import Foundation

/// A calendar day on the wall clock, independent of time zones: day 0 is January 1, 1970.
/// Grouping thousands of photos by day uses plain arithmetic on these instead of calendar lookups.
public struct CivilDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(number: Int) { self.number = number }

    public init(year: Int, month: Int, day: Int) {
        number = Self.days(year: year, month: month, day: day)
    }

    /// The day a moment falls on in a time zone.
    public init(_ date: Date, in timeZone: TimeZone) {
        let local = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        number = Int((local / 86_400).rounded(.down))
    }

    public static func < (lhs: CivilDay, rhs: CivilDay) -> Bool { lhs.number < rhs.number }

    public var year: Int { components.year }
    public var month: Int { components.month }
    public var day: Int { components.day }

    /// 1 for Sunday through 7 for Saturday, as `Calendar` numbers weekdays.
    public var weekday: Int {
        let zeroBasedFromSunday = number >= -4 ? (number + 4) % 7 : (number + 5) % 7 + 6
        return zeroBasedFromSunday + 1
    }

    public func adding(days: Int) -> CivilDay { CivilDay(number: number + days) }

    /// Midnight at the start of the day in the calendar's time zone (or the first moment of the day, where
    /// midnight is skipped for daylight saving time).
    public func start(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: Double(number) * 86_400)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// The year, month and day: days-from-civil and civil-from-days are the standard proleptic Gregorian formulas.
    public var components: (year: Int, month: Int, day: Int) {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The number of days in a month.
    public static func daysIn(year: Int, month: Int) -> Int {
        let next = month == 12 ? (year + 1, 1) : (year, month + 1)
        return days(year: next.0, month: next.1, day: 1) - days(year: year, month: month, day: 1)
    }
}

/// The six weeks a month calendar shows: the month's days, with the end of the month before and the start of
/// the month after filling the first and last weeks.
public struct MonthGrid: Hashable, Sendable {
    public let year: Int
    public let month: Int
    /// 42 days, starting on the week's first day.
    public let days: [CivilDay]

    /// - Parameter firstWeekday: 1 for Sunday, 2 for Monday…, as `Calendar.firstWeekday`.
    public init(year: Int, month: Int, firstWeekday: Int) {
        self.year = year
        self.month = month
        let first = CivilDay(year: year, month: month, day: 1)
        let lead = (first.weekday - firstWeekday + 7) % 7
        let start = first.adding(days: -lead)
        days = (0..<42).map { start.adding(days: $0) }
    }

    public func contains(_ day: CivilDay) -> Bool { day.year == year && day.month == month }

    /// The month before or after, `offset` months away.
    public static func month(_ year: Int, _ month: Int, offset: Int) -> (year: Int, month: Int) {
        let index = year * 12 + (month - 1) + offset
        let newYear = index >= 0 ? index / 12 : (index - 11) / 12
        return (newYear, index - newYear * 12 + 1)
    }
}
