import Foundation

// Kobe's work (spec §6.10): one page from three sources, because Hermes has no run list and no stop endpoint.
// The app knows its own runs (chat turns, quick asks: live over SSE); Kobe Agent describes the runs it started
// itself in the `work` snapshot; `GET /api/jobs` gives the cron jobs; the Claude Code socket gives the sessions and
// what they wait for. The page draws `WorkFeed.compose`'s sections as they come.

/// Something that waits for an answer: Kobe's approval or a Claude Code permission or question. The app lists them
/// in the order they would be answered; only the one on screen can be (`answerable`), the others wait their turn.
public struct WorkWaiting: Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    /// The Claude Code project it comes from, so that session isn't listed again under Running.
    public let project: String?
    public let answerable: Bool

    public init(id: String, title: String, detail: String, project: String? = nil, answerable: Bool) {
        self.id = id; self.title = title; self.detail = detail; self.project = project; self.answerable = answerable
    }
}

/// A Claude Code session that is working, from its last hook event.
public struct WorkSession: Equatable, Sendable {
    public let project: String
    public let step: String

    public init(project: String, step: String) {
        self.project = project; self.step = step
    }
}

public struct WorkRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case running, waiting, scheduled, done }

    /// Where the row came from, which says what its buttons do: Stop on `.app` closes the app's stream, Stop on
    /// `.agent` is a `WidgetAction.stopRun`, Allow / Deny on `.request` answer that request.
    public enum Source: Equatable, Sendable {
        case app(String), agent(String), claude(String), request(String), job(String), finished(String)
    }

    public let id: String
    public let title: String
    public let detail: String
    /// The right-hand text: "running · 40 s", "waiting", "next in 17 h", "4 min ago".
    public let meta: String
    public let kind: Kind
    public let stoppable: Bool
    public let answerable: Bool
    public let source: Source

    /// What Return does on the selected row. It never answers and never stops: a waiting request is brought into
    /// focus (answering stays Allow / Deny clicks and the armed ⌥⌘Y / ⌥⌘N); everything else does nothing.
    public enum ReturnAction: Equatable, Sendable { case focusRequest(String), none }

    public var returnAction: ReturnAction {
        if kind == .waiting, case .request(let id) = source { return .focusRequest(id) }
        return .none
    }
}

public struct WorkSection: Equatable, Sendable {
    public let title: String
    public let rows: [WorkRow]

    public init(title: String, rows: [WorkRow]) {
        self.title = title; self.rows = rows
    }
}

public enum WorkFeed {
    /// Waiting for you, Running, Scheduled, Done today; an empty section is left out. Waiting comes first: the
    /// request ⌥⌘Y would answer is the first thing on the page.
    public static func compose(appRuns: [WorkRun], snapshot: WorkSnapshotData?, jobs: [HermesJob],
                               waiting: [WorkWaiting], sessions: [WorkSession] = [], now: Date,
                               calendar: Calendar = .current) -> [WorkSection] {
        // Stable: the one on screen first, the queued ones after it in their order.
        let ordered = waiting.filter(\.answerable) + waiting.filter { !$0.answerable }
        let waitingRows = ordered.map {
            WorkRow(id: "request:\($0.id)", title: $0.title, detail: $0.detail, meta: $0.answerable ? "waiting" : "queued",
                    kind: .waiting, stoppable: false, answerable: $0.answerable, source: .request($0.id))
        }

        let waitingProjects = Set(waiting.compactMap(\.project))
        let appIDs = Set(appRuns.map(\.id))
        let agentRuns = (snapshot?.runs ?? []).filter { !appIDs.contains($0.id) }.sorted { $0.startedAt > $1.startedAt }
        let running = appRuns.map { runRow($0, source: .app($0.id), now: now) }
            + agentRuns.map { runRow($0, source: .agent($0.id), now: now) }
            + sessions.filter { !waitingProjects.contains($0.project) }.map {
                WorkRow(id: "claude:\($0.project)", title: "Claude Code · \($0.project)", detail: $0.step, meta: "working",
                        kind: .running, stoppable: false, answerable: false, source: .claude($0.project))
            }

        let scheduled = jobs.sorted(by: jobOrder).map {
            WorkRow(id: "job:\($0.id)", title: $0.name, detail: "cron · \(HermesJob.readable($0.schedule))",
                    meta: $0.paused ? "paused" : next($0.nextRunAt, now: now, calendar: calendar),
                    kind: .scheduled, stoppable: false, answerable: false, source: .job($0.id))
        }

        let done = (snapshot?.finished ?? [])
            .filter { calendar.isDate($0.startedAt, inSameDayAs: now) }
            .sorted { $0.startedAt > $1.startedAt }
            .map {
                let age = PageText.age($0.startedAt, now: now)
                return WorkRow(id: "done:\($0.id)", title: $0.name, detail: $0.progress ?? "", meta: age == "now" ? "now" : "\(age) ago",
                               kind: .done, stoppable: false, answerable: false, source: .finished($0.id))
            }

        return [("Waiting for you", waitingRows), ("Running", running), ("Scheduled", scheduled), ("Done today", done)]
            .filter { !$0.1.isEmpty }
            .map { WorkSection(title: $0.0, rows: $0.1) }
    }

    /// The rows ↑↓ move over, in the order they are drawn (the answerable requests first, then each section).
    public static func selectable(_ sections: [WorkSection]) -> [WorkRow] {
        sections.flatMap(\.rows)
    }

    /// The header chip's "N running".
    public static func runningCount(_ sections: [WorkSection]) -> Int {
        sections.flatMap(\.rows).filter { $0.kind == .running }.count
    }

    /// How long a run has been going: "40 s", "5 min", "2 h".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h"
    }

    /// When a job runs next: "due now", "next in 5 min", "next in 17 h", then the day ("next Mon").
    public static func next(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "not scheduled" }
        let ahead = date.timeIntervalSince(now)
        if ahead < 30 { return "due now" }
        if ahead < 3600 { return "next in \(max(1, Int((ahead / 60).rounded()))) min" }
        if ahead < 86_400 { return "next in \(Int(ahead / 3600)) h" }
        return "next \(PageText.day(date, now: now, calendar: calendar))"
    }

    private static func runRow(_ run: WorkRun, source: WorkRow.Source, now: Date) -> WorkRow {
        let id = switch source {
        case .app(let id): "app:\(id)"
        default: "agent:\(run.id)"
        }
        return WorkRow(id: id, title: run.name, detail: run.progress ?? "", meta: "running · \(elapsed(now.timeIntervalSince(run.startedAt)))",
                       kind: .running, stoppable: run.stoppable, answerable: false, source: source)
    }

    /// Soonest first; a job with no next run after those that have one; paused ones last; then by name.
    private static func jobOrder(_ a: HermesJob, _ b: HermesJob) -> Bool {
        func rank(_ job: HermesJob) -> Int { job.paused ? 2 : job.nextRunAt == nil ? 1 : 0 }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        if let x = a.nextRunAt, let y = b.nextRunAt, x != y { return x < y }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
