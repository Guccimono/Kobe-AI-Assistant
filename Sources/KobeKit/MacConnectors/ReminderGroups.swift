import Foundation

/// The Reminders page's sections, in the order they show.
public enum ReminderGroup: String, CaseIterable, Sendable {
    case overdue, today, tomorrow, later, noDate
}

public enum ReminderGroups {
    /// A due time is overdue once it has passed; a due day (no time) only once that day is over.
    public static func isOverdue(_ item: ReminderItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = item.due else { return false }
        if item.dueHasTime { return due < now }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }

    public static func groupOf(_ item: ReminderItem, now: Date, calendar: Calendar = .current) -> ReminderGroup {
        guard let due = item.due else { return .noDate }
        if isOverdue(item, now: now, calendar: calendar) { return .overdue }
        if calendar.isDate(due, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: tomorrow) {
            return .tomorrow
        }
        return .later
    }

    /// Non-empty groups in order; each sorted by due, then title. Completed items stay put (the page fades them).
    public static func group(_ items: [ReminderItem], now: Date,
                             calendar: Calendar = .current) -> [(ReminderGroup, [ReminderItem])] {
        let byGroup = Dictionary(grouping: items) { groupOf($0, now: now, calendar: calendar) }
        return ReminderGroup.allCases.compactMap { group in
            guard let list = byGroup[group], !list.isEmpty else { return nil }
            return (group, list.sorted { a, b in
                let da = a.due ?? .distantFuture, db = b.due ?? .distantFuture
                return da != db ? da < db : a.title.localizedStandardCompare(b.title) == .orderedAscending
            })
        }
    }

    /// The row's due text: "14:30", "Today", "Tomorrow 10:00", "Yesterday 10:00", "Oct 21", "Oct 29 09:00".
    public static func dueText(_ item: ReminderItem, now: Date, calendar: Calendar = .current) -> String {
        guard let due = item.due else { return "" }
        let time = item.dueHasTime ? MacBuilders.clock(due, calendar) : nil
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: due)).day ?? 0
        let day: String? = switch days {
        case 0: time == nil ? "Today" : nil
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default: PageText.when(due, now: now, calendar: calendar)
        }
        return [day, time].compactMap { $0 }.joined(separator: " ")
    }
}
