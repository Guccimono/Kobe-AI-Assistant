import Foundation

/// The four Mac snapshots, from what Kobe App read in Mail, Calendar, Reminders and Notes. Always `source: app`.
public enum MacBuilders {
    public static let mailLimit = 30, mailPreview = 140
    public static let notesLimit = 12, noteLines = 3, noteChars = 240
    /// Caps on what reaches the snapshot: a name or title, a link, a note's body; and how many reminders.
    public static let textLimit = 200, urlLimit = 500, bodyLimit = 2000, remindersLimit = 200

    /// `unreadTotal` is the inbox's whole unread count; without it, the unread among `messages`.
    public static func mail(messages: [MailMessage], unreadTotal: Int? = nil, appRunning: Bool, lastRead: Date?,
                            now: Date, calendar: Calendar = .current) -> WidgetSnapshot<MailSnapshotData> {
        let sorted = messages.sorted { a, b in a.unread != b.unread ? a.unread : a.at > b.at }
        let kept = sorted.prefix(mailLimit).map { m in
            var m = m
            m.sender = clip(m.sender, textLimit)
            m.subject = clip(m.subject, textLimit)
            m.account = clip(m.account, textLimit)
            m.preview = clip(oneLine(m.preview), mailPreview)
            return m
        }
        let unread = unreadTotal ?? messages.filter(\.unread).count
        let detail = appRunning ? "" : closed("Mail", lastRead: lastRead, calendar: calendar)
        return WidgetSnapshot(id: .mail, updatedAt: now, status: .ok,
                              headline: unread > 0 ? "\(unread) unread" : "Inbox clear", detail: detail,
                              data: MailSnapshotData(unread: unread, appRunning: appRunning, messages: Array(kept)))
    }

    public static func notes(notes: [NoteItem], appRunning: Bool, lastRead: Date?, now: Date,
                             calendar: Calendar = .current) -> WidgetSnapshot<NotesSnapshotData> {
        let kept = notes.sorted { $0.modified > $1.modified }.prefix(notesLimit).map { n in
            var n = n
            // Notes' plain text starts with the title again: drop that line.
            var lines = n.snippet.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.first == n.title.trimmingCharacters(in: .whitespaces) { lines.removeFirst() }
            n.snippet = clip(lines.prefix(noteLines).joined(separator: "\n"), noteChars)
            n.title = clip(n.title, textLimit)
            n.folder = clip(n.folder, textLimit)
            return n
        }
        let detail = appRunning ? "" : closed("Notes", lastRead: lastRead, calendar: calendar)
        return WidgetSnapshot(id: .notes, updatedAt: now, status: .ok,
                              headline: SnapshotBuilders.plural(kept.count, "note"), detail: detail,
                              data: NotesSnapshotData(appRunning: appRunning, notes: Array(kept)))
    }

    public static func agenda(events: [AgendaEvent], calendars: [AgendaCalendar], from: Date, to: Date, now: Date,
                              calendar: Calendar = .current) -> WidgetSnapshot<AgendaSnapshotData> {
        let clipped: [AgendaEvent] = events.map { (e: AgendaEvent) -> AgendaEvent in
            var e = e
            e.title = clip(e.title, textLimit)
            e.location = e.location.map { clip($0, textLimit) }
            e.url = e.url.map { clip($0, urlLimit) }
            e.notes = e.notes.map { clip($0, bodyLimit) }
            return e
        }
        let sorted = clipped.sorted { (a: AgendaEvent, b: AgendaEvent) -> Bool in
            a.start != b.start ? a.start < b.start : a.title < b.title
        }
        let calendars: [AgendaCalendar] = calendars.map { (c: AgendaCalendar) -> AgendaCalendar in
            var c = c
            c.name = clip(c.name, textLimit)
            return c
        }
        let timed = sorted.filter { !$0.allDay }
        let headline: String
        if let running = timed.first(where: { $0.start <= now && now < $0.end }) {
            headline = "Now: \(running.title)"
        } else if let next = timed.first(where: { $0.start > now && calendar.isDate($0.start, inSameDayAs: now) }) {
            headline = "Next: \(next.title) at \(clock(next.start, calendar))"
        } else {
            headline = "Nothing else today"
        }
        return WidgetSnapshot(id: .agenda, updatedAt: now, status: .ok, headline: headline,
                              detail: SnapshotBuilders.plural(sorted.count, "event"),
                              data: AgendaSnapshotData(from: from, to: to, calendars: calendars, events: sorted))
    }

    public static func reminders(_ items: [ReminderItem], now: Date,
                                 calendar: Calendar = .current) -> WidgetSnapshot<RemindersSnapshotData> {
        let open = items.filter { !$0.completed }
        let overdue = open.filter { ReminderGroups.isOverdue($0, now: now, calendar: calendar) }.count
        let headline = overdue > 0 ? "\(overdue) overdue" : open.isEmpty ? "All done" : "\(open.count) to do"
        // Counted on all; past the cap the snapshot keeps the soonest due (undated last).
        let capped = items.count <= remindersLimit ? items : items.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): x < y
            case (_?, nil): true
            default: false
            }
        }
        let kept = capped.prefix(remindersLimit).map { r in
            var r = r
            r.title = clip(r.title, textLimit)
            r.list = clip(r.list, textLimit)
            r.notes = r.notes.map { clip($0, bodyLimit) }
            return r
        }
        return WidgetSnapshot(id: .reminders, updatedAt: now, status: overdue > 0 ? .needsYou : .ok,
                              headline: headline, detail: "",
                              data: RemindersSnapshotData(overdue: overdue, reminders: Array(kept)))
    }

    /// macOS refused access: the page and Kobe Agent both read how to fix it.
    public static func denied(_ id: WidgetID, app: String, now: Date = .now) -> WidgetSnapshot<EmptyData> {
        WidgetSnapshot(id: id, updatedAt: now, status: .failed, headline: "No access", detail: "",
                       error: "Kobe can't read \(app): allow it in System Settings › Privacy & Security",
                       data: EmptyData())
    }

    /// "Ana" from "Ana <ana@example.com>"; the address when there is no name.
    public static func senderName(_ sender: String) -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "<") else { return trimmed }
        let name = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        if !name.isEmpty { return name }
        return trimmed[trimmed.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
    }

    // MARK: Helpers

    /// "Mail is closed · last read 14:28".
    static func closed(_ app: String, lastRead: Date?, calendar: Calendar) -> String {
        guard let lastRead else { return "\(app) is closed" }
        return "\(app) is closed · last read \(clock(lastRead, calendar))"
    }

    /// "14:28" in the calendar's time zone.
    public static func clock(_ date: Date, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
