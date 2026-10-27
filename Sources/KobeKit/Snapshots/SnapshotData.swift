import Foundation

// Page-specific `data` payloads. Flat, ISO 8601 dates, money in minor units plus currency. Keys are snake_case on
// the wire; the decoder's `.convertFromSnakeCase` maps them to these property names.

/// `data` for a snapshot that has nothing to show (for example `not_set_up`).
public struct EmptyData: Codable, Sendable, Equatable { public init() {} }

public struct StripeSnapshotData: Codable, Sendable, Equatable {
    public var period: String
    public var total: Int
    public var count: Int
    public var failed: Int
    public var refunds: Int
    public var currency: String
    public var available: Int
    public var pending: Int
    public var nextPayout: Date?
    public var payments: [StripeSnapshotPayment]
}

public struct StripeSnapshotPayment: Codable, Sendable, Equatable {
    public var id: String
    public var customer: String
    public var plan: String?
    public var amount: Int
    public var currency: String
    public var status: String
    public var at: Date
    public var retryAt: Date?
    public var url: String?
}

/// Only the chat list lives in the file; conversations' messages stay in the app.
public struct WhatsAppSnapshotData: Codable, Sendable, Equatable {
    public var unread: Int
    public var chats: [WhatsAppSnapshotChat]
}

public struct WhatsAppSnapshotChat: Codable, Sendable, Equatable {
    public var jid: String
    public var name: String
    public var isGroup: Bool
    public var unread: Int
    public var last: Date
    public var preview: String
    public var previewKind: String
    public var mentionsMe: Bool
}

public struct GitHubSnapshotData: Codable, Sendable, Equatable {
    public var needsYou: [GitHubSnapshotItem]
    public var myPRs: [GitHubSnapshotItem]
    public var mains: [GitHubSnapshotItem]
    /// Contributions for the last 7 days.
    public var activity: [Int]
    public var total: Int
    public var stars: Int

    // `convertFromSnakeCase` turns the wire key `my_prs` into "myPrs".
    private enum CodingKeys: String, CodingKey {
        case needsYou, myPRs = "myPrs", mains, activity, total, stars
    }
}

public struct GitHubSnapshotItem: Codable, Sendable, Equatable {
    public var id: String
    public var repo: String
    public var number: Int?
    public var title: String
    /// "passing", "running", "failing" or "unknown".
    public var state: String
    public var branch: String?
    public var author: String?
    public var url: String
}

public struct VercelSnapshotData: Codable, Sendable, Equatable {
    public var projects: [VercelSnapshotProject]
}

public struct VercelSnapshotProject: Codable, Sendable, Equatable {
    public var name: String
    public var state: String
    public var branch: String?
    public var commit: String?
    public var at: Date
    public var url: String?
    public var isProduction: Bool
}

/// Google Analytics and Search Console over `period_days`, with the period before for the deltas. `calls` stays
/// nil and `business_profile` "waiting_access" until Google grants the Business Profile API.
public struct GoogleSnapshotData: Codable, Sendable, Equatable {
    public var periodDays: Int
    public var visitors: Int
    public var visitorsPrev: Int
    public var clicks: Int
    public var clicksPrev: Int
    /// Search Console's average position: lower is better.
    public var position: Double
    public var positionPrev: Double
    public var calls: Int?
    public var callsPrev: Int?
    public var topQueries: [GoogleTopQuery]
    /// Clicks per day, oldest first.
    public var dailyClicks: [Int]
    /// "waiting_access" or "ok".
    public var businessProfile: String
    public var reportUrls: GoogleReportURLs
}

public struct GoogleTopQuery: Codable, Sendable, Equatable {
    public var query: String
    public var clicks: Int
}

public struct GoogleReportURLs: Codable, Sendable, Equatable {
    public var analytics: String
    public var search: String
}

public enum NowAction: String, Codable, Sendable, Equatable {
    case open, reply, done, review, visit, allow

    /// An action a newer Kobe Agent invents reads as Open, which every row supports.
    public init(from decoder: Decoder) throws {
        self = NowAction(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .open
    }
}

public struct NowRow: Codable, Sendable, Equatable {
    public var id: String
    public var source: WidgetID
    public var title: String
    public var detail: String
    public var tint: String?
    public var action: NowAction?
    public var until: Date?
    /// Where Visit and Review go (the PR, the deploy, the payment); optional, so older files still decode.
    public var url: String? = nil
}

public struct NowSnapshotData: Codable, Sendable, Equatable {
    public var current: NowRow?
    public var needsYou: [NowRow]
    public var clients: [NowRow]
    public var brief: String?
}

public struct WorkRun: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var startedAt: Date
    public var progress: String?
    public var stoppable: Bool

    /// Public so the app can describe its own runs (a chat turn, a quick ask) the way the snapshot does.
    public init(id: String, name: String, startedAt: Date, progress: String? = nil, stoppable: Bool) {
        self.id = id; self.name = name; self.startedAt = startedAt; self.progress = progress; self.stoppable = stoppable
    }
}

public struct WorkSnapshotData: Codable, Sendable, Equatable {
    public var runs: [WorkRun]
    public var finished: [WorkRun]

    public init(runs: [WorkRun], finished: [WorkRun]) {
        self.runs = runs; self.finished = finished
    }
}

// The Mac connectors. Kobe App reads these four apps (Kobe Agent can't) and writes them for Kobe Agent to read.

/// Unread first, then the latest, across every account's inbox.
public struct MailSnapshotData: Codable, Sendable, Equatable {
    public var unread: Int
    /// False when Mail was closed at the last read: the messages are from then.
    public var appRunning: Bool
    public var messages: [MailMessage]
    public init(unread: Int, appRunning: Bool, messages: [MailMessage]) {
        self.unread = unread; self.appRunning = appRunning; self.messages = messages
    }
}

public struct MailMessage: Codable, Sendable, Equatable {
    /// The RFC 822 Message-ID without the angle brackets; `message://` opens it in Mail.
    public var id: String
    public var sender: String
    public var subject: String
    /// One line, about 140 characters of the body.
    public var preview: String
    public var at: Date
    public var unread: Bool
    public var account: String
    public init(id: String, sender: String, subject: String, preview: String, at: Date, unread: Bool, account: String) {
        self.id = id; self.sender = sender; self.subject = subject; self.preview = preview; self.at = at
        self.unread = unread; self.account = account
    }
}

/// Yesterday to 30 days ahead.
public struct AgendaSnapshotData: Codable, Sendable, Equatable {
    public var from: Date
    public var to: Date
    public var calendars: [AgendaCalendar]
    public var events: [AgendaEvent]
    public init(from: Date, to: Date, calendars: [AgendaCalendar], events: [AgendaEvent]) {
        self.from = from; self.to = to; self.calendars = calendars; self.events = events
    }
}

public struct AgendaCalendar: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// "#RRGGBB".
    public var color: String
    public init(id: String, name: String, color: String) { self.id = id; self.name = name; self.color = color }
}

public struct AgendaEvent: Codable, Sendable, Equatable {
    /// EventKit's `eventIdentifier`.
    public var id: String
    public var title: String
    /// The calendar's `id`.
    public var calendar: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String?
    public var url: String?
    public var notes: String?
    public init(id: String, title: String, calendar: String, start: Date, end: Date, allDay: Bool,
                location: String? = nil, url: String? = nil, notes: String? = nil) {
        self.id = id; self.title = title; self.calendar = calendar; self.start = start; self.end = end
        self.allDay = allDay; self.location = location; self.url = url; self.notes = notes
    }
}

/// Incomplete reminders, plus the ones ticked in the last few seconds (for the undo).
public struct RemindersSnapshotData: Codable, Sendable, Equatable {
    public var overdue: Int
    public var reminders: [ReminderItem]
    public init(overdue: Int, reminders: [ReminderItem]) { self.overdue = overdue; self.reminders = reminders }
}

public struct ReminderItem: Codable, Sendable, Equatable {
    /// EventKit's `calendarItemIdentifier`.
    public var id: String
    public var title: String
    public var list: String
    /// "#RRGGBB".
    public var listColor: String
    public var due: Date?
    /// False for a date-only due: `due` is that day's start and no time is shown.
    public var dueHasTime: Bool
    public var completed: Bool
    public var notes: String?
    public init(id: String, title: String, list: String, listColor: String, due: Date?, dueHasTime: Bool,
                completed: Bool, notes: String? = nil) {
        self.id = id; self.title = title; self.list = list; self.listColor = listColor; self.due = due
        self.dueHasTime = dueHasTime; self.completed = completed; self.notes = notes
    }
}

/// The latest notes by modified date.
public struct NotesSnapshotData: Codable, Sendable, Equatable {
    /// False when Notes was closed at the last read: the notes are from then.
    public var appRunning: Bool
    public var notes: [NoteItem]
    public init(appRunning: Bool, notes: [NoteItem]) { self.appRunning = appRunning; self.notes = notes }
}

public struct NoteItem: Codable, Sendable, Equatable {
    /// Notes' own id (`x-coredata://…`).
    public var id: String
    public var title: String
    /// Up to three lines of plain text, joined by "\n".
    public var snippet: String
    public var folder: String
    public var modified: Date
    public init(id: String, title: String, snippet: String, folder: String, modified: Date) {
        self.id = id; self.title = title; self.snippet = snippet; self.folder = folder; self.modified = modified
    }
}
