import Foundation

/// Works out new dates for photos being moved in time, all at once. Every function keeps the photos in the order
/// they already had, so a batch never shuffles.
public enum Redate {
    /// How photos dropped on a day get their times.
    public enum TimeChoice: Hashable, Sendable {
        /// Each photo keeps its own time of day.
        case keepTimes
        /// Every photo gets this time of day (hour, minute), one second apart in their current order.
        case setTime(hour: Int, minute: Int)
    }

    /// One photo's move: where it was and where it goes.
    public struct Change: Hashable, Sendable {
        public let id: PhotoID
        public let from: Date
        public let to: Date

        public init(id: PhotoID, from: Date, to: Date) {
            self.id = id
            self.from = from
            self.to = to
        }
    }

    /// Moves photos to a day. Their order is their current date order.
    public static func move(_ items: [(id: PhotoID, date: Date)], to day: CivilDay, time: TimeChoice,
                            calendar: Calendar) -> [Change] {
        let sorted = ordered(items)
        switch time {
        case .keepTimes:
            return sorted.map { item in
                let clock = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: item.date)
                var target = DateComponents(year: day.year, month: day.month, day: day.day)
                target.hour = clock.hour
                target.minute = clock.minute
                target.second = clock.second
                target.nanosecond = clock.nanosecond
                return Change(id: item.id, from: item.date, to: calendar.date(from: target) ?? item.date)
            }
        case let .setTime(hour, minute):
            let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour,
                                                           minute: minute)) ?? day.start(in: calendar)
            return sorted.enumerated().map { index, item in
                Change(id: item.id, from: item.date, to: start.addingTimeInterval(Double(index)))
            }
        }
    }

    /// Gives every photo this exact date and time, one second apart in their current order.
    public static func set(_ items: [(id: PhotoID, date: Date)], to date: Date) -> [Change] {
        ordered(items).enumerated().map { index, item in
            Change(id: item.id, from: item.date, to: date.addingTimeInterval(Double(index)))
        }
    }

    /// Moves every photo by the same amount, so the earliest lands on `date` and the gaps between them stay.
    public static func shift(_ items: [(id: PhotoID, date: Date)], firstTo date: Date) -> [Change] {
        let sorted = ordered(items)
        guard let first = sorted.first else { return [] }
        let offset = date.timeIntervalSince(first.date)
        return sorted.map { Change(id: $0.id, from: $0.date, to: $0.date.addingTimeInterval(offset)) }
    }

    /// Places photos right after `previous` and before `next`, the photos they were dropped between. They follow
    /// `previous` a second apart, or closer together when the gap is smaller; with no `previous`, they end a second
    /// (or less) before `next`. With neither, nothing moves.
    public static func place(_ items: [(id: PhotoID, date: Date)], after previous: Date?, before next: Date?) -> [Change] {
        let sorted = ordered(items)
        let count = Double(sorted.count)
        guard count > 0 else { return [] }
        if let previous {
            var step = 1.0
            if let next, next > previous {
                step = min(1.0, next.timeIntervalSince(previous) / (count + 1))
            } else if let next, next <= previous {
                step = 0.001
            }
            return sorted.enumerated().map { index, item in
                Change(id: item.id, from: item.date, to: previous.addingTimeInterval(step * Double(index + 1)))
            }
        }
        if let next {
            return sorted.enumerated().map { index, item in
                Change(id: item.id, from: item.date, to: next.addingTimeInterval(-(count - Double(index))))
            }
        }
        return []
    }

    /// The opposite changes, to undo a move.
    public static func reversed(_ changes: [Change]) -> [Change] {
        changes.map { Change(id: $0.id, from: $0.to, to: $0.from) }
    }

    /// Photos in date order; photos with the same date keep the order they were given in.
    static func ordered(_ items: [(id: PhotoID, date: Date)]) -> [(id: PhotoID, date: Date)] {
        items.enumerated().sorted { lhs, rhs in
            lhs.element.date == rhs.element.date ? lhs.offset < rhs.offset : lhs.element.date < rhs.element.date
        }.map(\.element)
    }
}
