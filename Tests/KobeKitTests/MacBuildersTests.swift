import Foundation
import Testing
@testable import KobeKit

/// Fixed clock: 2026-10-24T15:00:00Z is 09:00 in Mexico City (UTC-6, no daylight saving since 2022).
struct MacBuildersTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-24T15:00:00Z")!
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return c
    }()

    /// Local time `h:m` on today + `day`.
    func local(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        let today = cal.startOfDay(for: now)
        let d = cal.date(byAdding: .day, value: day, to: today)!
        return cal.date(bySettingHour: h, minute: m, second: 0, of: d)!
    }

    func reminder(_ id: String, _ due: Date?, time: Bool = true, done: Bool = false) -> ReminderItem {
        ReminderItem(id: id, title: id, list: "Work", listColor: "#F5A524", due: due, dueHasTime: time, completed: done)
    }

    func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> AgendaEvent {
        AgendaEvent(id: title, title: title, calendar: "cal", start: start, end: end, allDay: allDay)
    }

    // MARK: Reminders

    @Test func remindersGroupInOrder() {
        let items = [
            reminder("g", nil, time: false),
            reminder("f", local(5, 10)),
            reminder("e", local(1, 10)),
            reminder("d", local(0, 18)),
            reminder("c", local(0, 0), time: false),
            reminder("b", local(0, 8)),
            reminder("a", local(-1, 10)),
        ]
        let groups = ReminderGroups.group(items, now: now, calendar: cal)
        #expect(groups.map(\.0) == [.overdue, .today, .tomorrow, .later, .noDate])
        #expect(groups[0].1.map(\.id) == ["a", "b"])
        #expect(groups[1].1.map(\.id) == ["c", "d"])
        let snap = MacBuilders.reminders(items, now: now, calendar: cal)
        #expect(snap.data.overdue == 2)
        #expect(snap.status == .needsYou && snap.headline == "2 overdue")
        #expect(snap.id == .reminders && snap.source == .app)
    }

    @Test func dateOnlyDueTodayIsNotOverdueButYesterdayIs() {
        #expect(!ReminderGroups.isOverdue(reminder("t", local(0, 0), time: false), now: now, calendar: cal))
        #expect(ReminderGroups.isOverdue(reminder("y", local(-1, 0), time: false), now: now, calendar: cal))
    }

    @Test func completedStayInTheirGroup() {
        let groups = ReminderGroups.group([reminder("x", local(0, 18), done: true)], now: now, calendar: cal)
        #expect(groups.map(\.0) == [.today])
    }

    @Test func noneOverdueIsOk() {
        let three = [reminder("a", local(0, 18)), reminder("b", local(1, 9)), reminder("c", nil, time: false)]
        let snap = MacBuilders.reminders(three, now: now, calendar: cal)
        #expect(snap.status == .ok && snap.headline == "3 to do" && snap.data.overdue == 0)
        #expect(MacBuilders.reminders([], now: now, calendar: cal).headline == "All done")
    }

    // MARK: Mail

    @Test func mailUnreadFirstAndClipped() {
        let long = String(repeating: "word ", count: 50) + "\nsecond line\n" + String(repeating: "x", count: 250)
        let messages: [MailMessage] = (0..<40).map { (i: Int) -> MailMessage in
            let at = now.addingTimeInterval(Double(-i) * 600)
            let preview = i == 0 ? long : "p"
            return MailMessage(id: "m\(i)", sender: "S", subject: "s", preview: preview, at: at,
                               unread: i % 8 == 3, account: "Google")
        }
        let snap = MacBuilders.mail(messages: messages.shuffled(), appRunning: true, lastRead: now, now: now,
                                    calendar: cal)
        #expect(snap.data.messages.count == 30)
        #expect(snap.data.messages.prefix(5).map(\.id) == ["m3", "m11", "m19", "m27", "m35"])
        #expect(snap.data.messages[5].id == "m0" && snap.data.messages[6].id == "m1")
        let clipped = snap.data.messages[5].preview
        #expect(clipped.count <= 140 && !clipped.contains("\n"))
        #expect(snap.data.unread == 5 && snap.data.appRunning)
        #expect(snap.status == .ok && snap.headline == "5 unread" && snap.detail == "")
    }

    @Test func mailInboxClear() {
        let read = [MailMessage(id: "a", sender: "S", subject: "s", preview: "p", at: now, unread: false, account: "G")]
        #expect(MacBuilders.mail(messages: read, appRunning: true, lastRead: now, now: now, calendar: cal).headline
            == "Inbox clear")
    }

    @Test func mailClosedDetail() {
        let snap = MacBuilders.mail(messages: [], appRunning: false, lastRead: local(-1, 14, 28), now: now,
                                    calendar: cal)
        #expect(snap.detail == "Mail is closed · last read 14:28")
        #expect(snap.status == .ok && !snap.data.appRunning)
    }

    // MARK: Notes

    @Test func notesNewestTwelveThreeLines() {
        let notes: [NoteItem] = (0..<15).map { (i: Int) -> NoteItem in
            let snippet = i == 0 ? "a\nb\nc\nd\ne" : String(repeating: "y", count: 1000)
            return NoteItem(id: "n\(i)", title: "t\(i)", snippet: snippet, folder: "Notes",
                            modified: now.addingTimeInterval(Double(-i) * 3600))
        }
        let snap = MacBuilders.notes(notes: notes.shuffled(), appRunning: true, lastRead: now, now: now, calendar: cal)
        #expect(snap.data.notes.count == 12)
        #expect(snap.data.notes.map(\.id) == (0..<12).map { "n\($0)" })
        #expect(snap.data.notes[0].snippet == "a\nb\nc")
        #expect(snap.data.notes[1].snippet.count <= 240)
        #expect(snap.headline == "12 notes" && snap.status == .ok)
        let closed = MacBuilders.notes(notes: [], appRunning: false, lastRead: local(0, 8, 5), now: now, calendar: cal)
        #expect(closed.detail == "Notes is closed · last read 08:05")
    }

    // MARK: Agenda

    @Test func agendaHeadlines() {
        let (from, to) = AgendaTime.range(now: now, calendar: cal)
        func headline(_ events: [AgendaEvent]) -> String {
            MacBuilders.agenda(events: events, calendars: [], from: from, to: to, now: now, calendar: cal).headline
        }
        #expect(headline([event("Standup", local(0, 8, 45), local(0, 9, 15)), event("Lunch", local(0, 14, 30), local(0, 15))])
            == "Now: Standup")
        #expect(headline([event("Lunch", local(0, 14, 30), local(0, 15)), event("Gym", local(0, 18), local(0, 19))])
            == "Next: Lunch at 14:30")
        #expect(headline([event("Day off", local(0, 0), local(1, 0), allDay: true), event("Tomorrow", local(1, 9), local(1, 10))])
            == "Nothing else today")
    }

    @Test func agendaSortsByStart() {
        let (from, to) = AgendaTime.range(now: now, calendar: cal)
        let snap = MacBuilders.agenda(events: [event("b", local(1, 9), local(1, 10)), event("a", local(0, 12), local(0, 13))],
                                      calendars: [AgendaCalendar(id: "cal", name: "Work", color: "#F4505E")],
                                      from: from, to: to, now: now, calendar: cal)
        #expect(snap.data.events.map(\.id) == ["a", "b"])
        #expect(snap.status == .ok && snap.data.calendars.count == 1)
    }

    @Test func rangeIsYesterdayToThirtyDaysAhead() {
        let (from, to) = AgendaTime.range(now: now, calendar: cal)
        #expect(from == local(-1, 0))
        #expect(to == local(31, 0))
    }

    @Test func nextRewriteIsTheEarliestBoundary() {
        // An event starting exactly now is skipped; its end is the next boundary.
        #expect(AgendaTime.nextRewrite(now: now, events: [event("x", now, local(0, 9, 20))], reminders: [], calendar: cal)
            == local(0, 9, 20))
        #expect(AgendaTime.nextRewrite(now: now, events: [], reminders: [], calendar: cal) == now.addingTimeInterval(3600))
        let late = local(0, 23, 30)
        #expect(AgendaTime.nextRewrite(now: late, events: [], reminders: [], calendar: cal) == local(1, 0))
        #expect(AgendaTime.nextRewrite(now: now, events: [], reminders: [reminder("r", local(0, 9, 10))], calendar: cal)
            == local(0, 9, 10))
        let past = [event("p", local(-1, 9), local(-1, 10))]
        #expect(AgendaTime.nextRewrite(now: now, events: past, reminders: [reminder("o", local(-1, 9))], calendar: cal) > now)
    }

    // MARK: Denied

    @Test func deniedSaysHowToFix() {
        let snap = MacBuilders.denied(.agenda, app: "Calendar", now: now)
        #expect(snap.status == .failed && snap.headline == "No access")
        #expect(snap.error == "Kobe can't read Calendar: allow it in System Settings › Privacy & Security")
        #expect(snap.id == .agenda)
    }

    // MARK: Settings copy

    @Test func macStatusCopy() {
        #expect(MacConnectionCopy.status(.agenda, on: false, access: .granted, running: true, problem: nil) == "Off")
        #expect(MacConnectionCopy.status(.agenda, on: true, access: .granted, running: true, problem: nil) == "On")
        #expect(MacConnectionCopy.status(.reminders, on: true, access: .notAsked, running: true, problem: nil)
            == "Waiting for your OK in System Settings")
        #expect(MacConnectionCopy.status(.agenda, on: true, access: .denied, running: true, problem: nil)
            == "Kobe can't read Calendar: allow it in System Settings › Privacy & Security")
        #expect(MacConnectionCopy.status(.mail, on: true, access: .notAsked, running: false, problem: nil)
            == "Open Mail to finish setup")
        // Set up already: a closed Mail is fine, the page says it.
        #expect(MacConnectionCopy.status(.mail, on: true, access: .granted, running: false, problem: nil) == "On")
        #expect(MacConnectionCopy.status(.notes, on: true, access: .granted, running: true, problem: "Couldn't read: x")
            == "Couldn't read: x")
        #expect(MacConnectionCopy.runner(.mail, owner: .app) == "on this Mac")
        #expect(MacConnectionCopy.runner(.agenda, owner: .agent) == "on this Mac")
        #expect(MacConnectionCopy.runner(.stripe, owner: .agent) == "via Kobe Agent")
        #expect(MacConnectionCopy.runner(.stripe, owner: .app) == "via the app")
    }

    // MARK: Page helpers

    @Test func hexColours() {
        #expect(RGB(hex: "#1E90FF") == RGB(0x1E90FF))
        #expect(RGB(hex: "f5a524") == RGB(0xF5A524))
        #expect(RGB(hex: "#XYZ") == nil && RGB(hex: "") == nil && RGB(hex: "#1234567") == nil)
    }

    @Test func reminderDueText() {
        func due(_ d: Date?, time: Bool = true) -> String {
            ReminderGroups.dueText(reminder("x", d, time: time), now: now, calendar: cal)
        }
        #expect(due(local(0, 14, 30)) == "14:30")
        #expect(due(local(0, 0), time: false) == "Today")
        #expect(due(local(1, 10)) == "Tomorrow 10:00")
        #expect(due(local(1, 0), time: false) == "Tomorrow")
        #expect(due(local(-1, 10)) == "Yesterday 10:00")
        #expect(due(local(-3, 0), time: false) == "Oct 21")
        #expect(due(local(5, 9)) == "Oct 29 09:00")
        #expect(due(nil) == "")
    }

    @Test func senderNames() {
        #expect(MacBuilders.senderName("Ana <ana@example.com>") == "Ana")
        #expect(MacBuilders.senderName("\"Ana B.\" <ana@example.com>") == "Ana B.")
        #expect(MacBuilders.senderName("<ana@example.com>") == "ana@example.com")
        #expect(MacBuilders.senderName("ana@example.com") == "ana@example.com")
        #expect(MacBuilders.senderName("") == "")
    }

    // MARK: Review fixes

    @Test func mailUsesTheInboxUnreadCount() {
        let one = [MailMessage(id: "a", sender: "S", subject: "s", preview: "p", at: now, unread: true, account: "G")]
        let snap = MacBuilders.mail(messages: one, unreadTotal: 212, appRunning: true, lastRead: now, now: now, calendar: cal)
        #expect(snap.headline == "212 unread" && snap.data.unread == 212)
    }

    @Test func notesDropTheRepeatedTitle() {
        let note = NoteItem(id: "n", title: "Menu ideas", snippet: "Menu ideas\r\nTacos\r\nAgua\nFlan\nMore", folder: "Notes",
                            modified: now)
        let snap = MacBuilders.notes(notes: [note], appRunning: true, lastRead: now, now: now, calendar: cal)
        #expect(snap.data.notes[0].snippet == "Tacos\nAgua\nFlan")
    }

    @Test func everyFreeTextFieldIsClipped() {
        let big = String(repeating: "w", count: 10_000)
        let m = MacBuilders.mail(messages: [MailMessage(id: "a", sender: big, subject: big, preview: big, at: now, unread: false,
                                                        account: big)],
                                 appRunning: true, lastRead: now, now: now, calendar: cal).data.messages[0]
        #expect(m.sender.count <= 200 && m.subject.count <= 200 && m.account.count <= 200)
        let n = MacBuilders.notes(notes: [NoteItem(id: "n", title: big, snippet: big, folder: big, modified: now)],
                                  appRunning: true, lastRead: now, now: now, calendar: cal).data.notes[0]
        #expect(n.title.count <= 200 && n.folder.count <= 200)
        let (from, to) = AgendaTime.range(now: now, calendar: cal)
        let e = MacBuilders.agenda(events: [AgendaEvent(id: "e", title: big, calendar: "c", start: now, end: now, allDay: false,
                                                        location: big, url: big, notes: big)],
                                   calendars: [AgendaCalendar(id: "c", name: big, color: "#000000")],
                                   from: from, to: to, now: now, calendar: cal)
        #expect(e.data.events[0].title.count <= 200 && (e.data.events[0].location?.count ?? 0) <= 200)
        #expect((e.data.events[0].url?.count ?? 0) <= 500 && (e.data.events[0].notes?.count ?? 0) <= 2000)
        #expect(e.data.calendars[0].name.count <= 200)
        let r = MacBuilders.reminders([ReminderItem(id: "r", title: big, list: big, listColor: "#000000", due: nil,
                                                    dueHasTime: false, completed: false, notes: big)], now: now, calendar: cal)
        #expect(r.data.reminders[0].title.count <= 200 && r.data.reminders[0].list.count <= 200)
        #expect((r.data.reminders[0].notes?.count ?? 0) <= 2000)
        let many = (0..<500).map { reminder("r\($0)", nil, time: false) }
        #expect(MacBuilders.reminders(many, now: now, calendar: cal).data.reminders.count == MacBuilders.remindersLimit)
    }

    @Test func leftGoesBackFromTheEventDetail() {
        #expect(AgendaNavigation.move(.left, detailOpen: true) == .back)
        #expect(AgendaNavigation.move(.escape, detailOpen: true) == .back)
        #expect(AgendaNavigation.move(.left, detailOpen: false) == .month(-1))
        #expect(AgendaNavigation.move(.right, detailOpen: false) == .month(1))
        #expect(AgendaNavigation.move(.right, detailOpen: true) == .none)
        #expect(AgendaNavigation.move(.enter, detailOpen: false) == .open)
        #expect(AgendaNavigation.move(.down, detailOpen: false) == .select(.down))
    }
}
