import Foundation
import Testing
@testable import KobeKit

// Kobe's work (spec §6.10): one list from the app's own runs, the `work` snapshot, the cron jobs and what waits
// for an answer. Waiting comes first, so the request on screen is the first thing seen.

private let now = Date(timeIntervalSince1970: 1_792_760_400)   // 2026-10-23 13:00 UTC
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func run(_ id: String, _ name: String, secondsAgo: TimeInterval, progress: String? = nil, stoppable: Bool = true) -> WorkRun {
    WorkRun(id: id, name: name, startedAt: now.addingTimeInterval(-secondsAgo), progress: progress, stoppable: stoppable)
}

private func job(_ id: String, next: TimeInterval?, paused: Bool = false) -> HermesJob {
    HermesJob(id: id, name: id, schedule: "30 7 * * *", nextRunAt: next.map { now.addingTimeInterval($0) }, paused: paused)
}

@Test func waitingBeforeRunning() {
    let sections = WorkFeed.compose(
        appRuns: [run("chat", "Answering the Google review", secondsAgo: 40)],
        snapshot: WorkSnapshotData(runs: [run("r1", "WhatsApp triage", secondsAgo: 300, stoppable: false)], finished: []),
        jobs: [job("Morning brief", next: 3600)],
        waiting: [WorkWaiting(id: "c1", title: "Claude Code · menuly-v4", detail: "npm run build", project: "menuly-v4", answerable: true),
                  WorkWaiting(id: "c2", title: "Claude Code · kobe", detail: "rm -rf build", project: "kobe", answerable: false)],
        sessions: [WorkSession(project: "menuly-v4", step: "Running a command"), WorkSession(project: "site", step: "Editing")],
        now: now, calendar: utc)
    #expect(sections.map(\.title) == ["Waiting for you", "Running", "Scheduled"])
    // The answerable request first, then the queued one.
    #expect(sections[0].rows.map(\.answerable) == [true, false])
    #expect(sections[0].rows.allSatisfy { $0.kind == .waiting && !$0.stoppable })
    #expect(sections[0].rows[0].source == .request("c1"))
    // The app's run, Kobe Agent's run, then Claude Code sessions; a session already waiting isn't listed twice.
    let running = sections[1].rows
    #expect(running.map(\.title) == ["Answering the Google review", "WhatsApp triage", "Claude Code · site"])
    #expect(running.map(\.source) == [.app("chat"), .agent("r1"), .claude("site")])
    #expect(running.map(\.stoppable) == [true, false, false])
    #expect(running[0].meta == "running · 40 s")
    #expect(running[1].meta == "running · 5 min")
    #expect(WorkFeed.runningCount(sections) == 3)
}

@Test func nothingToShowIsNoSection() {
    #expect(WorkFeed.compose(appRuns: [], snapshot: nil, jobs: [], waiting: [], now: now, calendar: utc).isEmpty)
}

@Test func scheduledSortedByNextRun() {
    let sections = WorkFeed.compose(
        appRuns: [], snapshot: nil,
        jobs: [job("paused", next: 60, paused: true), job("later", next: 17 * 3600), job("never", next: nil),
               job("soon", next: 5 * 60), job("due", next: -10)],
        waiting: [], now: now, calendar: utc)
    #expect(sections.map(\.title) == ["Scheduled"])
    let rows = sections[0].rows
    #expect(rows.map(\.title) == ["due", "soon", "later", "never", "paused"])
    #expect(rows.map(\.meta) == ["due now", "next in 5 min", "next in 17 h", "not scheduled", "paused"])
    #expect(rows[0].detail == "cron · every day 7:30")
    #expect(rows.allSatisfy { $0.kind == .scheduled && !$0.stoppable && !$0.answerable })
}

@Test func doneTodayOnly() {
    let finished = [run("f1", "Backed up my memory", secondsAgo: 4 * 60, progress: "acme-notes · 323 files"),
                    run("f2", "Yesterday's brief", secondsAgo: 14 * 3600),
                    run("f3", "Morning brief", secondsAgo: 5 * 3600)]
    let sections = WorkFeed.compose(appRuns: [], snapshot: WorkSnapshotData(runs: [], finished: finished),
                                    jobs: [], waiting: [], now: now, calendar: utc)
    #expect(sections.map(\.title) == ["Done today"])
    // Today's only (13:00 UTC: 14 h ago is yesterday), newest first.
    #expect(sections[0].rows.map(\.title) == ["Backed up my memory", "Morning brief"])
    #expect(sections[0].rows[0].detail == "acme-notes · 323 files")
    #expect(sections[0].rows[0].meta == "4 min ago")
    #expect(sections[0].rows.allSatisfy { $0.kind == .done && !$0.stoppable })
}

@Test func elapsedAndNextReadShort() {
    #expect(WorkFeed.elapsed(5) == "5 s")
    #expect(WorkFeed.elapsed(125) == "2 min")
    #expect(WorkFeed.elapsed(2 * 3600 + 60) == "2 h")
    #expect(WorkFeed.next(nil, now: now, calendar: utc) == "not scheduled")
    #expect(WorkFeed.next(now.addingTimeInterval(20), now: now, calendar: utc) == "due now")
    #expect(WorkFeed.next(now.addingTimeInterval(30), now: now, calendar: utc) == "next in 1 min")
}

@Test func returnOnlyFocusesWaitingRequests() {
    let sections = WorkFeed.compose(
        appRuns: [run("chat", "Answering", secondsAgo: 5)],
        snapshot: WorkSnapshotData(runs: [run("r1", "Triage", secondsAgo: 60)], finished: [run("f1", "Backup", secondsAgo: 60)]),
        jobs: [job("Morning brief", next: 3600)],
        waiting: [WorkWaiting(id: "c1", title: "Claude Code · a", detail: "ls", answerable: true),
                  WorkWaiting(id: "c2", title: "Claude Code · b", detail: "rm", answerable: false)],
        now: now, calendar: utc)
    let rows = WorkFeed.selectable(sections)
    // Drawn order: the answerable request, the queued one, runs, cron, done.
    #expect(rows.map(\.id) == ["request:c1", "request:c2", "app:chat", "agent:r1", "job:Morning brief", "done:f1"])
    // Return never answers or stops anything: it brings a waiting request into focus, else does nothing.
    #expect(rows.map(\.returnAction) == [.focusRequest("c1"), .focusRequest("c2"), .none, .none, .none, .none])
}
