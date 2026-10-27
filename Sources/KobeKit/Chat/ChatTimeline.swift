import Foundation

/// Day dividers and message times for the chat.
public enum ChatTimeline {
    /// The ids of the lines that start a new day compared with the line before (the first line always does).
    public static func dividers(_ lines: [ChatLine], calendar: Calendar) -> Set<UUID> {
        var out = Set<UUID>()
        var previous: Date?
        for line in lines {
            if previous.map({ !calendar.isDate($0, inSameDayAs: line.at) }) ?? true { out.insert(line.id) }
            previous = line.at
        }
        return out
    }

    /// "Today", "Yesterday", else "Saturday 24 October".
    public static func label(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return format("EEEE d MMMM", date, calendar)
    }

    /// "09:05" (24 h unless the calendar's locale uses 12 h).
    public static func time(_ date: Date, calendar: Calendar) -> String {
        format("j:mm", date, calendar)
    }

    /// Formatters are costly and the chat asks on every render: one per (template, calendar, zone, locale).
    /// `DateFormatter` is not Sendable, so the cache is touched, and the formatters used, only under the lock.
    private nonisolated(unsafe) static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    private static func format(_ template: String, _ date: Date, _ calendar: Calendar) -> String {
        let locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        let key = [template, "\(calendar.identifier)", calendar.timeZone.identifier, locale.identifier].joined(separator: "|")
        lock.lock()
        defer { lock.unlock() }
        let f: DateFormatter
        if let cached = cache[key] {
            f = cached
        } else {
            f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(template)
            cache[key] = f
        }
        return f.string(from: date)
    }
}
