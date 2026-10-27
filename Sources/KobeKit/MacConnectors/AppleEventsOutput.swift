import Foundation

/// Why a read of Mail or Notes didn't work.
public enum MacReadProblem: Error, Equatable, Sendable {
    case notRunning, denied, other(String)
}

public enum AppleEventsError {
    /// -600: the app isn't running. -1743 / -1744: Automation was refused (or would need a prompt).
    public static func from(code: Int) -> MacReadProblem {
        switch code {
        case -600: .notRunning
        case -1743, -1744: .denied
        default: .other("Apple Events error \(code)")
        }
    }

    /// osascript ends its error line with the code: "… Not authorized to send Apple events to Mail. (-1743)".
    public static func from(stderr: String) -> MacReadProblem {
        let line = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasSuffix(")"), let open = line.lastIndex(of: "("),
           let code = Int(line[line.index(after: open)..<line.index(before: line.endIndex)]) {
            return from(code: code)
        }
        return .other(line.isEmpty ? "Couldn't read" : "Couldn't read: \(line.prefix(120))")
    }
}

/// Parses what `MacScripts` return. Never trusts the text: a record with the wrong field count or a date that isn't
/// a whole number of seconds is dropped, and nothing here can crash.
public enum AppleEventsOutput {
    static let fieldSeparator: Character = "\u{1F}", recordSeparator: Character = "\u{1E}"

    public static func records(_ text: String, fields: Int) -> [[String]] {
        text.split(separator: recordSeparator, omittingEmptySubsequences: true).compactMap { raw in
            let parts = raw.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            // AppleScript may hand back a trailing line break after the last record.
            if parts.count == 1, parts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return parts.count == fields ? parts : nil
        }
    }

    /// The Mail script's answer: the inbox's whole unread count (its header record) and the messages.
    public static func mailRead(_ text: String, now: Date) -> (unread: Int?, messages: [MailMessage]) {
        var unread: Int?
        if let header = records(text, fields: 2).first(where: { $0[0] == "#unread" }) {
            unread = Int(header[1].trimmingCharacters(in: .whitespaces))
        }
        let messages: [MailMessage] = records(text, fields: 7).compactMap { f in
            guard let secs = Int(f[3].trimmingCharacters(in: .whitespaces)) else { return nil }
            let id = f[0].trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            guard !id.isEmpty else { return nil }
            return MailMessage(id: id, sender: f[1], subject: f[2], preview: f[6],
                               at: now.addingTimeInterval(TimeInterval(secs)), unread: f[4] != "true", account: f[5])
        }
        return (unread, messages)
    }

    /// Each note once (a note listed in two folders keeps the first).
    public static func notesIndex(_ text: String, now: Date)
        -> [(id: String, title: String, folder: String, modified: Date)] {
        var seen = Set<String>()
        return records(text, fields: 4).compactMap { f in
            guard !f[0].isEmpty, let secs = Int(f[3].trimmingCharacters(in: .whitespaces)),
                  seen.insert(f[0]).inserted else { return nil }
            return (f[0], f[1], f[2], now.addingTimeInterval(TimeInterval(secs)))
        }
    }

    public static func notesBodies(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for f in records(text, fields: 2) where !f[0].isEmpty { out[f[0]] = f[1] }
        return out
    }

    /// The editor's read of one note.
    public static func noteRead(_ text: String, now: Date)
        -> (modified: Date, locked: Bool, attachments: Int, html: String, plain: String)? {
        guard let f = records(text, fields: 5).first, let secs = Int(f[0].trimmingCharacters(in: .whitespaces)),
              let attachments = Int(f[2].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (now.addingTimeInterval(TimeInterval(secs)), f[1] == "true", attachments, f[3], f[4])
    }

    /// The save's answer.
    public static func noteWrite(_ text: String, now: Date) -> NoteWriteResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#changed") { return .changed }
        if trimmed.hasPrefix("#locked") { return .locked }
        guard let f = records(text, fields: 2).first, f[0] == "#saved",
              let secs = Int(f[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return .saved(now.addingTimeInterval(TimeInterval(secs)))
    }
}

/// What saving a note did.
public enum NoteWriteResult: Equatable, Sendable {
    case saved(Date), changed, locked
}
