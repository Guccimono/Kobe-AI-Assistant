import Foundation
import KobeKit

/// `--demo`'s Calendar and Reminders: made-up events and reminders around now, never EventKit.
@MainActor
final class DemoCalendar: CalendarSource {
    private var items: [ReminderItem]
    private let start = Calendar.current.startOfDay(for: .now)

    init() {
        let day = Calendar.current.startOfDay(for: .now)
        items = [
            ReminderItem(id: "demo-r1", title: "Send the October invoice", list: "Work", listColor: "#F5A524",
                         due: day.addingTimeInterval(-86_400 + 10 * 3600), dueHasTime: true, completed: false),
            ReminderItem(id: "demo-r2", title: "Buy coffee", list: "Home", listColor: "#1E90FF", due: day,
                         dueHasTime: false, completed: false),
            ReminderItem(id: "demo-r3", title: "Call Example Client", list: "Work", listColor: "#F5A524",
                         due: day.addingTimeInterval(86_400 + 11 * 3600), dueHasTime: true, completed: false),
            ReminderItem(id: "demo-r4", title: "Menu ideas", list: "Home", listColor: "#1E90FF", due: nil,
                         dueHasTime: false, completed: false),
        ]
    }

    func access(_ kind: MacKind) -> MacAccess { .granted }
    func requestAccess(_ kind: MacKind) async -> Bool { true }

    func events(from: Date, to: Date) -> (calendars: [AgendaCalendar], events: [AgendaEvent]) {
        let calendars = [AgendaCalendar(id: "demo-work", name: "Work", color: "#F4505E"),
                         AgendaCalendar(id: "demo-home", name: "Home", color: "#1E90FF")]
        let now = Date()
        let events = [
            AgendaEvent(id: "demo-e1", title: "Standup", calendar: "demo-work", start: now.addingTimeInterval(-900),
                        end: now.addingTimeInterval(900), allDay: false, location: "Zoom",
                        url: "https://example.com/meet/standup"),
            AgendaEvent(id: "demo-e2", title: "Call with Example Client", calendar: "demo-work",
                        start: now.addingTimeInterval(2 * 3600), end: now.addingTimeInterval(2.5 * 3600), allDay: false,
                        location: "Café Roma", notes: "Bring the menu draft.\nAsk about the weekend."),
            AgendaEvent(id: "demo-e3", title: "Day off", calendar: "demo-home", start: start.addingTimeInterval(2 * 86_400),
                        end: start.addingTimeInterval(3 * 86_400), allDay: true),
            AgendaEvent(id: "demo-e4", title: "Trip", calendar: "demo-home", start: start.addingTimeInterval(5 * 86_400 + 9 * 3600),
                        end: start.addingTimeInterval(7 * 86_400 + 18 * 3600), allDay: false),
        ]
        return (calendars, events.filter { $0.end > from && $0.start < to })
    }

    func reminders() async -> [ReminderItem] { items }

    func setDone(_ id: String, _ done: Bool) throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].completed = done
    }

    func reminderLists() -> (lists: [ReminderList], defaultID: String?) {
        ([ReminderList(id: "demo-home", name: "Home", color: "#1E90FF"),
          ReminderList(id: "demo-work", name: "Work", color: "#F5A524")], "demo-home")
    }

    func addReminder(_ draft: ReminderDraft, list: String?) throws {
        let work = list == "demo-work"
        items.append(ReminderItem(id: "demo-r\(items.count + 1)", title: draft.title, list: work ? "Work" : "Home",
                                  listColor: work ? "#F5A524" : "#1E90FF", due: draft.due,
                                  dueHasTime: draft.dueHasTime, completed: false))
    }

    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

/// `--demo`'s Mail and Notes: the scripts' answers, made up, in their wire format.
struct DemoScripts: ScriptRunner {
    func run(_ source: String) async -> Result<String, MacReadProblem> {
        let us = "\u{1F}", rs = "\u{1E}"
        func records(_ rows: [[String]]) -> String { rows.map { $0.joined(separator: us) + rs }.joined() }
        if source.contains("set body of note") { return .success("#saved\(us)-1\(rs)") }
        if source.contains("password protected") {
            return .success(records([["-60", "false", "0",
                                      "<div><h1>Menu ideas</h1></div><div>Tacos al pastor</div><div>Agua de jamaica</div><ul><li>Flan</li></ul>",
                                      "Menu ideas\nTacos al pastor\nAgua de jamaica\nFlan"]]))
        }
        if source.contains("tell application \"Mail\"") {
            return .success(records([
                ["#unread", "2"],
                ["demo-1@example.com", "Example Client", "Menu for Saturday", "-1200", "false", "Google",
                 "Hi, could we add two dishes before the weekend? The terrace opens on Friday."],
                ["demo-2@example.com", "Stripe", "Your receipt", "-7200", "false", "iCloud", "Thanks for your payment."],
                ["demo-3@example.com", "Example Newsletter", "This week", "-90000", "true", "Google", "Five things."],
            ]))
        }
        if source == MacScripts.notesIndex {
            return .success(records([
                ["demo-n1", "Menu ideas", "Notes", "-3600"], ["demo-n2", "Trip", "Personal", "-86400"],
                ["demo-n3", "Groceries", "Notes", "-200000"],
            ]))
        }
        if source.contains("plaintext") {
            return .success(records([
                ["demo-n1", "Menu ideas\nTacos al pastor\nAgua de jamaica\nFlan"],
                ["demo-n2", "Trip\nBook the flight\nPack the charger"],
                ["demo-n3", "Groceries\nCoffee, limes, tortillas"],
            ]))
        }
        return .success("")
    }
}
