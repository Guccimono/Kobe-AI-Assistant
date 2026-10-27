import Foundation

/// The Agenda page's month grid and day list, Monday first whatever the locale's first weekday.
public enum AgendaGrid {
    /// Weeks of seven days, Monday to Sunday, with `nil` before the 1st and after the last day.
    public static func month(containing date: Date, calendar: Calendar) -> [[Date?]] {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        // Calendar weekdays: 1 Sunday … 7 Saturday; Monday-first column: 0 Monday … 6 Sunday.
        let lead = (calendar.component(.weekday, from: interval.start) + 5) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for offset in 0..<days.count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// The events that touch `day`: all-day ones first, then by start. A multi-day event shows on each of its days.
    public static func events(on day: Date, in events: [AgendaEvent], calendar: Calendar) -> [AgendaEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { touches($0, start, end) }.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            return a.start != b.start ? a.start < b.start : a.title < b.title
        }
    }

    /// Day numbers of `month` with at least one event (the grid's dots).
    public static func daysWithEvents(_ events: [AgendaEvent], in month: Date, calendar: Calendar) -> Set<Int> {
        var days = Set<Int>()
        for case let date? in self.month(containing: month, calendar: calendar).joined()
        where !self.events(on: date, in: events, calendar: calendar).isEmpty {
            days.insert(calendar.component(.day, from: date))
        }
        return days
    }

    /// "All day", "14:30 – 15:00", or for an event over several days "from 09:00", "All day", "until 10:00".
    public static func timeText(_ e: AgendaEvent, on day: Date, calendar: Calendar) -> String {
        if e.allDay { return "All day" }
        let startsToday = calendar.isDate(e.start, inSameDayAs: day)
        // An end at midnight belongs to the day before.
        let endsToday = calendar.isDate(e.end, inSameDayAs: day) || (startsToday && e.end <= endOfDay(day, calendar))
        let start = MacBuilders.clock(e.start, calendar), end = MacBuilders.clock(e.end, calendar)
        switch (startsToday, endsToday) {
        case (true, true): return "\(start) – \(end)"
        case (true, false): return "from \(start)"
        case (false, true): return "until \(end)"
        case (false, false): return "All day"
        }
    }

    private static func touches(_ e: AgendaEvent, _ start: Date, _ end: Date) -> Bool {
        if e.end <= e.start { return e.start >= start && e.start < end }
        return e.start < end && e.end > start
    }

    private static func endOfDay(_ day: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
    }
}
