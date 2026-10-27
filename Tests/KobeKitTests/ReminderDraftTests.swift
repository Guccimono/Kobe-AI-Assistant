import Foundation
import Testing
@testable import KobeKit

/// The date detector reads relative words against the real clock, so these compare against today.
struct ReminderDraftTests {
    let cal = Calendar.current
    var today: Date { cal.startOfDay(for: .now) }
    func day(_ offset: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        cal.date(byAdding: DateComponents(day: offset, hour: hour, minute: minute), to: today)!
    }

    @Test func titleAndTimeFromOneLine() {
        let d = ReminderDraft.parse("Call Ana tomorrow 10am")
        #expect(d == ReminderDraft(title: "Call Ana", due: day(1, 10), dueHasTime: true))
        #expect(ReminderDraft.parse("Call Ana tomorrow at 10am").title == "Call Ana")
        #expect(ReminderDraft.parse("Llamar a Ana mañana 10am") == ReminderDraft(title: "Llamar a Ana", due: day(1, 10),
                                                                                    dueHasTime: true))
    }

    @Test func aDayWithoutATimeIsDateOnly() {
        #expect(ReminderDraft.parse("Pay rent tomorrow") == ReminderDraft(title: "Pay rent", due: day(1), dueHasTime: false))
        let invoice = ReminderDraft.parse("Send invoice on Nov 3")
        #expect(invoice.title == "Send invoice" && !invoice.dueHasTime)
        #expect(invoice.due.map { cal.component(.hour, from: $0) } == 0)
    }

    @Test func noDateKeepsTheWholeLine() {
        #expect(ReminderDraft.parse("  Buy limes  ") == ReminderDraft(title: "Buy limes", due: nil, dueHasTime: false))
        #expect(ReminderDraft.parse("call 5551234").title == "call 5551234")
        #expect(ReminderDraft.parse("   ").isEmpty)
        // Only a date: the line stays the title.
        #expect(ReminderDraft.parse("tomorrow").title == "tomorrow")
    }

    @Test func dayChipsOverrideTheDetectedDay() {
        let timed = ReminderDraft.parse("Call Ana tomorrow 10am")
        #expect(timed.on(day: 0, calendar: cal).due == day(0, 10))
        #expect(timed.on(day: nil, calendar: cal) == ReminderDraft(title: "Call Ana", due: nil, dueHasTime: false))
        let plain = ReminderDraft.parse("Buy limes")
        #expect(plain.on(day: 1, calendar: cal) == ReminderDraft(title: "Buy limes", due: day(1), dueHasTime: false))
        #expect(plain.on(day: 1, calendar: cal).dayOffset(calendar: cal) == 1)
        #expect(timed.dayOffset(calendar: cal) == 1 && plain.dayOffset(calendar: cal) == nil)
    }

    @Test func listChipCycles() {
        let lists = [ReminderList(id: "a", name: "Reminders", color: "#000000"),
                     ReminderList(id: "b", name: "Acme", color: "#000000")]
        #expect(ReminderList.next(after: "a", in: lists)?.id == "b")
        #expect(ReminderList.next(after: "b", in: lists)?.id == "a")
        #expect(ReminderList.next(after: "gone", in: lists)?.id == "a")
        #expect(ReminderList.next(after: "a", in: []) == nil)
    }
}
