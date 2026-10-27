import Foundation

/// The keyboard selection on a page (or on Home's Now rows): ↑↓ move it, Return runs the selected row's primary
/// action. Pure, so the edges are tested; the page owns one and passes `focused:` to each `KitRow` from it.
/// Never wraps: at the last row ↓ stays, as in Finder and Mail.
public struct PageSelection: Equatable, Sendable {
    public enum Direction: Sendable { case up, down }

    public var index: Int?

    public init(index: Int? = nil) { self.index = index }

    /// From nothing, ↓ picks the first row and ↑ the last; then one step, stopping at either end.
    public mutating func move(_ direction: Direction, count: Int) {
        guard count > 0 else { index = nil; return }
        switch (direction, index) {
        case (.down, nil): index = 0
        case (.up, nil): index = count - 1
        case (.down, let i?): index = min(i + 1, count - 1)
        case (.up, let i?): index = max(min(i, count) - 1, 0)
        }
    }

    /// The list shrank (a chat read, a deploy gone): keep the selection on the last row that still exists.
    public mutating func clamp(count: Int) {
        guard let i = index else { return }
        index = count > 0 ? min(i, count - 1) : nil
    }

    /// The selected row, nil when nothing is selected or the index is past the end.
    public func current<T>(in rows: [T]) -> T? {
        guard let index, rows.indices.contains(index) else { return nil }
        return rows[index]
    }
}

/// A page's ↻: it spins until the snapshot's `updated_at` moves past what it was when the refresh started (the
/// first file, when there was none), or 20 s pass (spec §3.2).
public struct RefreshSpin: Equatable, Sendable {
    public static let timeout: TimeInterval = 20

    public let startedAt: Date
    public let baseline: Date?

    public init(startedAt: Date, baseline: Date?) {
        self.startedAt = startedAt
        self.baseline = baseline
    }

    public func isSpinning(current: Date?, now: Date = .now) -> Bool {
        guard now.timeIntervalSince(startedAt) < Self.timeout else { return false }
        return current == baseline
    }
}

/// Dates on the pages (spec §8): relative under a day, absolute after.
public enum PageText {
    /// "now", "14 min", "2 h", "6 d": how long ago (a deploy, a message).
    public static func age(_ date: Date, now: Date = .now) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        return "\(hours / 24) d"
    }

    /// When something happened: the clock time today, "yesterday", else the date ("Oct 20").
    public static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return format("HH:mm", date, calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return format("MMM d", date, calendar)
    }

    /// A day ahead (the next payout, a retry): the weekday within the coming week ("Mon"), else the date.
    public static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let ahead = date.timeIntervalSince(now)
        if ahead >= -86_400, ahead < 7 * 86_400 { return format("EEE", date, calendar) }
        return format("MMM d", date, calendar)
    }

    private static func format(_ pattern: String, _ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
