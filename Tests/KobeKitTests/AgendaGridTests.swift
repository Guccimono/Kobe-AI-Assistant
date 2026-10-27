import Foundation
import Testing
@testable import KobeKit

struct AgendaGridTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Mexico_City")!
        c.firstWeekday = 1   // a Sunday-first locale: the grid is Monday-first anyway
        return c
    }()

    func day(_ d: Int, _ h: Int = 0, _ m: Int = 0, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!
    }

    func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> AgendaEvent {
        AgendaEvent(id: id, title: id, calendar: "cal", start: start, end: end, allDay: allDay)
    }

    @Test func octoberStartsThursday() {
        let weeks = AgendaGrid.month(containing: day(24), calendar: cal)
        #expect(weeks.count == 5)
        #expect(weeks[0].count == 7 && weeks.allSatisfy { $0.count == 7 })
        #expect(weeks[0][0] == nil && weeks[0][1] == nil && weeks[0][2] == nil)
        #expect(weeks[0][3] == day(1) && weeks[0][6] == day(4))
        #expect(weeks[4][5] == day(31) && weeks[4][6] == nil)
    }

    @Test func multiDayEventOnEachDay() {
        let trip = event("trip", day(5, 9), day(7, 18))
        let all = [trip]
        #expect(AgendaGrid.events(on: day(4), in: all, calendar: cal).isEmpty)
        #expect(AgendaGrid.events(on: day(5), in: all, calendar: cal).map(\.id) == ["trip"])
        #expect(AgendaGrid.events(on: day(6), in: all, calendar: cal).map(\.id) == ["trip"])
        #expect(AgendaGrid.events(on: day(7), in: all, calendar: cal).map(\.id) == ["trip"])
        #expect(AgendaGrid.events(on: day(8), in: all, calendar: cal).isEmpty)
        // An all-day event ends at the next midnight: one day only.
        let off = event("off", day(10), day(11), allDay: true)
        #expect(AgendaGrid.events(on: day(11), in: [off], calendar: cal).isEmpty)
        // Crossing midnight: on both days.
        let late = event("late", day(12, 23), day(13, 1))
        #expect(AgendaGrid.events(on: day(13), in: [late], calendar: cal).map(\.id) == ["late"])
    }

    @Test func allDayFirst() {
        let list = [event("b", day(9, 14), day(9, 15)), event("a", day(9, 9), day(9, 10)), event("off", day(9), day(10), allDay: true)]
        #expect(AgendaGrid.events(on: day(9), in: list, calendar: cal).map(\.id) == ["off", "a", "b"])
    }

    @Test func timeTexts() {
        #expect(AgendaGrid.timeText(event("x", day(9), day(10), allDay: true), on: day(9), calendar: cal) == "All day")
        #expect(AgendaGrid.timeText(event("x", day(9, 14, 30), day(9, 15)), on: day(9), calendar: cal) == "14:30 – 15:00")
        let trip = event("trip", day(5, 9), day(7, 10))
        #expect(AgendaGrid.timeText(trip, on: day(5), calendar: cal) == "from 09:00")
        #expect(AgendaGrid.timeText(trip, on: day(6), calendar: cal) == "All day")
        #expect(AgendaGrid.timeText(trip, on: day(7), calendar: cal) == "until 10:00")
    }

    @Test func dotsForDaysWithEvents() {
        let list = [event("a", day(3, 9), day(3, 10)), event("trip", day(30, 9), day(2, 10, month: 11)),
                    event("sept", day(20, 9, month: 9), day(20, 10, month: 9))]
        #expect(AgendaGrid.daysWithEvents(list, in: day(24), calendar: cal) == [3, 30, 31])
        #expect(AgendaGrid.daysWithEvents(list, in: day(1, month: 11), calendar: cal) == [1, 2])
    }
}
