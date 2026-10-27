import Foundation

/// When Agenda and Reminders must be rewritten without a change from EventKit: what they say changes at the next
/// event start or end, the next due time, and midnight. The hour is the heartbeat.
public enum AgendaTime {
    public static func nextRewrite(now: Date, events: [AgendaEvent], reminders: [ReminderItem],
                                   calendar: Calendar = .current) -> Date {
        var candidates = [now.addingTimeInterval(3600)]
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            candidates.append(midnight)
        }
        for e in events { candidates += [e.start, e.end] }
        candidates += reminders.compactMap(\.due)
        return candidates.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)
    }

    /// The snapshot's range: the start of yesterday to the end of today + 30 days.
    public static func range(now: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let to = calendar.date(byAdding: .day, value: 31, to: today) ?? today
        return (from, to)
    }
}
