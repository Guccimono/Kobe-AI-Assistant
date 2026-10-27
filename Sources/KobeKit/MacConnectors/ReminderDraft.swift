import Foundation

/// A Reminders list, for the add field's list chip.
public struct ReminderList: Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String

    public init(id: String, name: String, color: String) {
        self.id = id; self.name = name; self.color = color
    }

    /// The chip's next list: the one after `id`, round; the first when `id` is gone.
    public static func next(after id: String?, in lists: [ReminderList]) -> ReminderList? {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return lists.first }
        return lists[(i + 1) % lists.count]
    }
}

/// One typed line ("Call Ana tomorrow 10am") as a reminder: the date words become the due, the rest the title.
public struct ReminderDraft: Equatable, Sendable {
    public var title: String
    public var due: Date?
    /// False for a day alone ("tomorrow", "Nov 3"): the due is that day's start.
    public var dueHasTime: Bool

    public init(title: String, due: Date?, dueHasTime: Bool) {
        self.title = title; self.due = due; self.dueHasTime = dueHasTime
    }

    public var isEmpty: Bool { title.isEmpty }

    /// macOS's date detector (English and Spanish); the first date found wins. A line that is only a date stays
    /// the title, with no due.
    public static func parse(_ text: String, calendar: Calendar = .current) -> ReminderDraft {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let date = match.date, let range = Range(match.range, in: line) else {
            return ReminderDraft(title: line, due: nil, dueHasTime: false)
        }
        var rest = line
        rest.removeSubrange(range)
        let title = tidy(rest)
        guard !title.isEmpty else { return ReminderDraft(title: line, due: nil, dueHasTime: false) }
        let timed = namesATime(String(line[range]))
        return ReminderDraft(title: title, due: timed ? date : calendar.startOfDay(for: date), dueHasTime: timed)
    }

    /// The Today / Tomorrow chips: that day, keeping the time; `nil` clears the due.
    public func on(day offset: Int?, now: Date = .now, calendar: Calendar = .current) -> ReminderDraft {
        guard let offset, let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))
        else { return ReminderDraft(title: title, due: nil, dueHasTime: false) }
        var draft = self
        if dueHasTime, let due {
            let time = calendar.dateComponents([.hour, .minute], from: due)
            draft.due = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day)
        } else {
            draft.due = day
        }
        return draft
    }

    /// 0 today, 1 tomorrow (the lit chip); nil for no due or another day.
    public func dayOffset(now: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let due else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: due)).day
        return days == 0 || days == 1 ? days : nil
    }

    // MARK: Helpers

    /// "10am", "14:30", "noon", "mediodía", "10 h": the detector gives a day alone 12:00, so this tells them apart.
    static func namesATime(_ words: String) -> Bool {
        words.lowercased().contains(/\d\s*(am|pm|a\.\s?m\.|p\.\s?m\.|h\b)|\d:\d|\bnoon\b|\bmidnight\b|mediod[ií]a|medianoche/)
    }

    /// Drops the joining word the date left behind ("Send invoice on" → "Send invoice") and stray spaces.
    static func tidy(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let joiners: Set<String> = ["on", "at", "by", "for", "el", "a", "las", "para", "el", "le", "à", "pour"]
        while let last = words.last, joiners.contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–"))
    }
}
