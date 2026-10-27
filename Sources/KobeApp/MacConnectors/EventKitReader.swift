import AppKit
import EventKit
import KobeKit

/// Calendar and Reminders through EventKit. Asks macOS only from `requestAccess`, which the Settings switch calls.
@MainActor
final class EventKitReader: CalendarSource {
    private let store = EKEventStore()

    func access(_ kind: MacKind) -> MacAccess {
        switch EKEventStore.authorizationStatus(for: kind == .reminders ? .reminder : .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestAccess(_ kind: MacKind) async -> Bool {
        do {
            return kind == .reminders ? try await store.requestFullAccessToReminders()
                                      : try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    func events(from: Date, to: Date) -> (calendars: [AgendaCalendar], events: [AgendaEvent]) {
        guard access(.agenda) == .granted else { return ([], []) }
        let calendars = store.calendars(for: .event).map {
            AgendaCalendar(id: $0.calendarIdentifier, name: $0.title, color: Self.hex($0.cgColor))
        }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: predicate).map { e in
            AgendaEvent(id: e.eventIdentifier ?? e.calendarItemIdentifier, title: e.title ?? "",
                        calendar: e.calendar?.calendarIdentifier ?? "", start: e.startDate, end: e.endDate,
                        allDay: e.isAllDay, location: e.location?.nilIfBlank, url: e.url?.absoluteString,
                        notes: e.notes?.nilIfBlank)
        }
        return (calendars, events)
    }

    /// Every incomplete reminder, plus the ones completed in the last 10 s (the page's undo).
    func reminders() async -> [ReminderItem] {
        guard access(.reminders) == .granted else { return [] }
        let now = Date()
        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: now.addingTimeInterval(-10),
                                                        ending: now.addingTimeInterval(1), calendars: nil)
        let a = await fetch(open), b = await fetch(done)
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0.id).inserted }
    }

    func setDone(_ id: String, _ done: Bool) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw CocoaError(.fileNoSuchFile)
        }
        reminder.isCompleted = done
        try store.save(reminder, commit: true)
    }

    func reminderLists() -> (lists: [ReminderList], defaultID: String?) {
        guard access(.reminders) == .granted else { return ([], nil) }
        let lists = store.calendars(for: .reminder).filter(\.allowsContentModifications).map {
            ReminderList(id: $0.calendarIdentifier, name: $0.title, color: Self.hex($0.cgColor))
        }
        return (lists, store.defaultCalendarForNewReminders()?.calendarIdentifier)
    }

    func addReminder(_ draft: ReminderDraft, list: String?) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        guard let target = list.flatMap({ store.calendar(withIdentifier: $0) }) ?? store.defaultCalendarForNewReminders()
        else { throw CocoaError(.fileNoSuchFile) }
        reminder.calendar = target
        if let due = draft.due {
            let parts: Set<Calendar.Component> = draft.dueHasTime ? [.year, .month, .day, .hour, .minute]
                                                                   : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: due)
            // A timed due rings, like one set in Reminders.
            if draft.dueHasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(reminder, commit: true)
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                               queue: .main) { _ in continuation.yield() }
            nonisolated(unsafe) let unsafeToken = token
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(unsafeToken) }
        }
    }

    private func fetch(_ predicate: NSPredicate) async -> [ReminderItem] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.item))
            }
        }
    }

    nonisolated private static func item(_ r: EKReminder) -> ReminderItem {
        let parts = r.dueDateComponents
        let hasTime = parts?.hour != nil
        var due: Date?
        if var parts {
            if !hasTime { parts.hour = 0; parts.minute = 0; parts.second = 0 }
            due = (parts.calendar ?? .current).date(from: parts)
        }
        return ReminderItem(id: r.calendarItemIdentifier, title: r.title ?? "", list: r.calendar?.title ?? "",
                            listColor: hex(r.calendar?.cgColor), due: due, dueHasTime: hasTime,
                            completed: r.isCompleted, notes: r.notes?.nilIfBlank)
    }

    /// "#RRGGBB" in sRGB; grey when the calendar has no colour.
    nonisolated static func hex(_ color: CGColor?) -> String {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "#8E8E93" }
        let c = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c[0], c[1], c[2])
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
