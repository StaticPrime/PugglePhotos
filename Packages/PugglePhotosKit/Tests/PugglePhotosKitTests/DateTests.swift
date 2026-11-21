import Foundation
import Testing
@testable import PugglePhotosKit

let newYork = TimeZone(identifier: "America/New_York")!

func calendar(_ timeZone: TimeZone = newYork) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0,
          in timeZone: TimeZone = newYork) -> Date {
    calendar(timeZone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

@Suite struct CivilDayTests {
    @Test func knownDays() {
        #expect(CivilDay(year: 1970, month: 1, day: 1).number == 0)
        #expect(CivilDay(year: 1969, month: 12, day: 31).number == -1)
        #expect(CivilDay(year: 2000, month: 3, day: 1).number == 11_017)
        let leap = CivilDay(year: 2024, month: 2, day: 29)
        #expect(leap.components == (2024, 2, 29))
        #expect(leap.adding(days: 1).components == (2024, 3, 1))
    }

    @Test func roundTripsEveryDayForCenturies() {
        for number in stride(from: -80_000, through: 80_000, by: 37) {
            let day = CivilDay(number: number)
            #expect(CivilDay(year: day.year, month: day.month, day: day.day) == day)
        }
    }

    @Test func weekdays() {
        #expect(CivilDay(year: 2026, month: 11, day: 17).weekday == 3) // Tuesday
        #expect(CivilDay(year: 1970, month: 1, day: 1).weekday == 5) // Thursday
        #expect(CivilDay(year: 1969, month: 12, day: 28).weekday == 1) // Sunday
    }

    @Test func monthLengths() {
        #expect(CivilDay.daysIn(year: 2024, month: 2) == 29)
        #expect(CivilDay.daysIn(year: 2100, month: 2) == 28)
        #expect(CivilDay.daysIn(year: 2000, month: 2) == 29)
        #expect(CivilDay.daysIn(year: 2026, month: 12) == 31)
    }

    @Test func dayOfAMomentDependsOnTheTimeZone() {
        let moment = date(2026, 11, 17, 22, 30) // 10:30 PM in New York is 3:30 AM the next day in London.
        #expect(CivilDay(moment, in: newYork) == CivilDay(year: 2026, month: 11, day: 17))
        #expect(CivilDay(moment, in: TimeZone(identifier: "Europe/London")!) == CivilDay(year: 2026, month: 11, day: 18))
    }

    @Test func startOfDay() {
        let day = CivilDay(year: 2026, month: 3, day: 8) // daylight saving time starts in New York
        #expect(day.start(in: calendar()) == date(2026, 3, 8, 0))
    }

    @Test func monthGrids() {
        let sunday = MonthGrid(year: 2026, month: 11, firstWeekday: 1)
        #expect(sunday.days.count == 42)
        #expect(sunday.days.first == CivilDay(year: 2026, month: 11, day: 1))
        let monday = MonthGrid(year: 2026, month: 11, firstWeekday: 2)
        #expect(monday.days.first == CivilDay(year: 2026, month: 10, day: 26))
        #expect(monday.contains(CivilDay(year: 2026, month: 11, day: 30)))
        #expect(!monday.contains(CivilDay(year: 2026, month: 10, day: 31)))
        #expect(MonthGrid.month(2026, 1, offset: -1) == (2025, 12))
        #expect(MonthGrid.month(2026, 12, offset: 1) == (2027, 1))
        #expect(MonthGrid.month(2026, 6, offset: -30) == (2023, 12))
    }
}

@Suite struct RedateTests {
    let items: [(id: PhotoID, date: Date)] = [
        ("b", date(2020, 1, 5, 15, 30)),
        ("a", date(2020, 1, 5, 9, 15, 20)),
        ("c", date(2021, 7, 4, 20, 0)),
    ]

    @Test func keepingTimesMovesEveryPhotoToTheDay() {
        let changes = Redate.move(items, to: CivilDay(year: 2019, month: 6, day: 14), time: .keepTimes, calendar: calendar())
        #expect(changes.map(\.id) == ["a", "b", "c"])
        #expect(changes.map(\.to) == [date(2019, 6, 14, 9, 15, 20), date(2019, 6, 14, 15, 30), date(2019, 6, 14, 20, 0)])
        #expect(changes.map(\.from) == [items[1].date, items[0].date, items[2].date])
    }

    @Test func keepingTimesAcrossDaylightSavingTime() {
        // A winter photo at 9:00 moved to a summer day is still at 9:00 on the clock.
        let changes = Redate.move([("w", date(2020, 1, 10, 9, 0))], to: CivilDay(year: 2020, month: 7, day: 10),
                                  time: .keepTimes, calendar: calendar())
        #expect(changes.first?.to == date(2020, 7, 10, 9, 0))
    }

    @Test func settingATimeKeepsTheOrderOneSecondApart() {
        let changes = Redate.move(items, to: CivilDay(year: 2019, month: 6, day: 14), time: .setTime(hour: 12, minute: 0),
                                  calendar: calendar())
        #expect(changes.map(\.id) == ["a", "b", "c"])
        #expect(changes.map(\.to) == [date(2019, 6, 14, 12, 0, 0), date(2019, 6, 14, 12, 0, 1), date(2019, 6, 14, 12, 0, 2)])
    }

    @Test func setAndShift() {
        let target = date(2018, 2, 2, 8, 0)
        #expect(Redate.set(items, to: target).map(\.to) == [target, target.addingTimeInterval(1), target.addingTimeInterval(2)])
        let shifted = Redate.shift(items, firstTo: target)
        #expect(shifted.map(\.id) == ["a", "b", "c"])
        #expect(shifted[0].to == target)
        #expect(shifted[1].to.timeIntervalSince(shifted[0].to) == items[0].date.timeIntervalSince(items[1].date))
        #expect(shifted[2].to.timeIntervalSince(shifted[0].to) == items[2].date.timeIntervalSince(items[1].date))
    }

    @Test func placingBetweenTwoPhotos() {
        let previous = date(2022, 5, 1, 10, 0), next = date(2022, 5, 1, 11, 0)
        let changes = Redate.place(items, after: previous, before: next)
        #expect(changes.map(\.to) == [previous.addingTimeInterval(1), previous.addingTimeInterval(2), previous.addingTimeInterval(3)])
        #expect(changes.allSatisfy { $0.to > previous && $0.to < next })
    }

    @Test func placingInATightGapStaysInside() {
        let previous = date(2022, 5, 1, 10, 0), next = previous.addingTimeInterval(1)
        let changes = Redate.place(items, after: previous, before: next)
        #expect(changes.allSatisfy { $0.to > previous && $0.to < next })
        #expect(changes.map(\.to) == changes.map(\.to).sorted())
    }

    @Test func placingAtTheEnds() {
        let next = date(2022, 5, 1, 10, 0)
        let before = Redate.place(items, after: nil, before: next)
        #expect(before.map(\.to) == [next.addingTimeInterval(-3), next.addingTimeInterval(-2), next.addingTimeInterval(-1)])
        let after = Redate.place(items, after: next, before: nil)
        #expect(after.map(\.to) == [next.addingTimeInterval(1), next.addingTimeInterval(2), next.addingTimeInterval(3)])
        #expect(Redate.place(items, after: nil, before: nil).isEmpty)
    }

    @Test func undoingSwapsEveryChange() {
        let changes = Redate.set(items, to: date(2018, 1, 1))
        let undo = Redate.reversed(changes)
        #expect(undo.map(\.to) == changes.map(\.from))
        #expect(undo.map(\.from) == changes.map(\.to))
    }

    @Test func sameDatesKeepTheirGivenOrder() {
        let same = date(2020, 1, 1)
        let changes = Redate.set([("x", same), ("y", same), ("z", same)], to: date(2021, 1, 1))
        #expect(changes.map(\.id) == ["x", "y", "z"])
    }
}

@Suite struct FormattingTests {
    let formatting = Formatting(locale: Locale(identifier: "en_US"), calendar: calendar())
    let today = CivilDay(year: 2026, month: 11, day: 17)

    @Test func dayTitles() {
        #expect(formatting.dayTitle(today, today: today) == "Today")
        #expect(formatting.dayTitle(today.adding(days: -1), today: today) == "Yesterday")
        #expect(formatting.dayTitle(CivilDay(year: 2026, month: 6, day: 14), today: today) == "Sunday, June 14")
        #expect(formatting.dayTitle(CivilDay(year: 2025, month: 6, day: 14), today: today) == "Saturday, June 14, 2025")
        #expect(formatting.monthTitle(year: 2025, month: 6) == "June 2025")
        #expect(formatting.yearTitle(2019) == "2019")
    }

    @Test func counts() {
        #expect(formatting.count(photos: 0, videos: 0) == "No photos")
        #expect(formatting.count(photos: 1, videos: 0) == "1 photo")
        #expect(formatting.count(photos: 0, videos: 2) == "2 videos")
        #expect(formatting.count(photos: 1234, videos: 1) == "1,234 photos and 1 video")
        #expect(formatting.count(items: 1) == "1 item")
    }

    @Test func durations() {
        #expect(Formatting.duration(5) == "0:05")
        #expect(Formatting.duration(75.4) == "1:15")
        #expect(Formatting.duration(3723) == "1:02:03")
        // A video whose length isn't a number, or is past all reason, shows none rather than stopping the app.
        #expect(Formatting.duration(.nan) == "0:00" && Formatting.duration(.infinity) == "0:00" && Formatting.duration(-4) == "0:00")
        #expect(Formatting.duration(1e300) == "99999:59:59")
    }

    @Test func ranges() {
        #expect(formatting.dateRange(from: nil, to: nil) == nil)
        #expect(formatting.dateRange(from: date(2025, 6, 14, 9), to: date(2025, 6, 14, 18)) == "Jun 14, 2025")
        let range = formatting.dateRange(from: date(2025, 6, 14), to: date(2025, 6, 20)) ?? ""
        #expect(range.contains("Jun 14") && range.contains("20, 2025"))
    }

    @Test func monthNames() {
        let names = formatting.monthNames
        #expect(names.count == 12)
        #expect(names[5].full == "June" && names[5].short == "Jun")
    }
}
