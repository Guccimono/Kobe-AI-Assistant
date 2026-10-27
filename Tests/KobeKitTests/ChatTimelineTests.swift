import Foundation
import Testing
@testable import KobeKit

@Suite("ChatTimeline")
struct ChatTimelineTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func line(_ at: Date) -> ChatLine { ChatLine(role: .user, text: "x", at: at) }

    @Test func firstLineStartsADay() {
        let a = line(date(20, 9))
        #expect(ChatTimeline.dividers([a], calendar: calendar) == [a.id])
        #expect(ChatTimeline.dividers([], calendar: calendar).isEmpty)
    }

    @Test func sameDayNoDivider() {
        let a = line(date(20, 9)), b = line(date(20, 23, 59))
        #expect(ChatTimeline.dividers([a, b], calendar: calendar) == [a.id])
    }

    @Test func newDayGetsADivider() {
        let a = line(date(20, 23, 59)), b = line(date(21, 0, 1)), c = line(date(21, 8))
        #expect(ChatTimeline.dividers([a, b, c], calendar: calendar) == [a.id, b.id])
    }

    @Test func labels() {
        let now = date(22, 12)
        #expect(ChatTimeline.label(date(22, 8), now: now, calendar: calendar) == "Today")
        #expect(ChatTimeline.label(date(21, 8), now: now, calendar: calendar) == "Yesterday")
        #expect(ChatTimeline.label(date(20, 8), now: now, calendar: calendar) == "Tuesday 20 October")
    }

    @Test func time() {
        #expect(ChatTimeline.time(date(20, 9, 5), calendar: calendar) == "09:05")
        var us = calendar
        us.locale = Locale(identifier: "en_US")
        #expect(ChatTimeline.time(date(20, 21, 5), calendar: us).hasPrefix("9:05"))
        #expect(ChatTimeline.time(date(20, 21, 5), calendar: us).contains("PM"))
    }
}
