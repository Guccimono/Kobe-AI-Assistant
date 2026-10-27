import Foundation
import Testing
@testable import KobeKit

@Suite(.serialized) struct SnapshotTests {
    private func fixture(_ name: String) -> Data { StubURLProtocol.fixture("snapshot_\(name).json") }

    @Test func decodesEveryFixture() throws {
        let stripe = try #require(SnapshotDecode.decode(fixture("stripe"), as: StripeSnapshotData.self))
        #expect(stripe.id == .stripe && stripe.status == .needsYou)
        #expect(stripe.data.payments.count == 2 && stripe.data.payments[1].retryAt != nil)
        #expect(stripe.data.nextPayout != nil && stripe.data.payments[0].plan == "Pro")

        let wa = try #require(SnapshotDecode.decode(fixture("whatsapp"), as: WhatsAppSnapshotData.self))
        #expect(wa.id == .whatsapp && wa.data.chats[1].isGroup && wa.data.chats[1].mentionsMe)
        #expect(wa.data.chats[0].previewKind == "text")

        let gh = try #require(SnapshotDecode.decode(fixture("github"), as: GitHubSnapshotData.self))
        #expect(gh.id == .github && gh.data.needsYou.count == 1 && gh.data.myPRs.count == 1)
        #expect(gh.data.mains[0].number == nil && gh.data.activity.count == 7)

        let vc = try #require(SnapshotDecode.decode(fixture("vercel"), as: VercelSnapshotData.self))
        #expect(vc.id == .vercel && vc.data.projects[0].isProduction && vc.data.projects[1].url == nil)

        let now = try #require(SnapshotDecode.decode(fixture("now"), as: NowSnapshotData.self))
        #expect(now.id == .now && now.data.current?.source == .agenda && now.data.needsYou[0].action == .reply)
        #expect(now.data.brief == "Two calls today.")
    }

    @Test func decodesGoogleSnapshot() throws {
        let g = try #require(SnapshotDecode.decode(fixture("google"), as: GoogleSnapshotData.self))
        #expect(g.id == .google && g.source == .agent && g.status == .ok)
        #expect(g.data.periodDays == 7 && g.data.visitors == 1240 && g.data.visitorsPrev == 1100)
        #expect(g.data.clicks == 312 && g.data.position == 8.4 && g.data.positionPrev == 9.1)
        #expect(g.data.calls == nil && g.data.callsPrev == nil)
        #expect(g.data.topQueries.map(\.query) == ["menu digital qr", "menuly"] && g.data.topQueries[0].clicks == 41)
        #expect(g.data.dailyClicks.count == 7 && g.data.businessProfile == "waiting_access")
        #expect(g.data.reportUrls.search.hasPrefix("https://search.google.com/"))
    }

    @Test func truncatedFileDecodesToNil() {
        #expect(SnapshotDecode.decode(fixture("truncated"), as: StripeSnapshotData.self) == nil)
        #expect(SnapshotDecode.decode(Data(), as: StripeSnapshotData.self) == nil)
    }

    @Test func newerVersionDecodesToNil() {
        #expect(SnapshotDecode.decode(fixture("future_version"), as: StripeSnapshotData.self) == nil)
    }

    @Test func freshnessRules() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SnapshotRules.freshness(updatedAt: now - 10, schedule: 300, now: now) == .fresh(age: 10))
        #expect(SnapshotRules.freshness(updatedAt: now - 901, schedule: 300, now: now) == .stale(age: 901))
        #expect(SnapshotRules.freshness(updatedAt: now - 900, schedule: 300, now: now) == .fresh(age: 900))
        #expect(SnapshotRules.freshness(updatedAt: nil, schedule: 300, now: now) == .unknown)
        #expect(SnapshotRules.freshness(updatedAt: now + 120, schedule: 300, now: now) == .unknown)
        #expect(SnapshotRules.freshness(updatedAt: now + 30, schedule: 300, now: now) == .fresh(age: 0))
    }

    @Test func metaTextCopy() {
        #expect(SnapshotRules.metaText(.fresh(age: 120)) == "updated 2 min ago · Kobe")
        #expect(SnapshotRules.metaText(.stale(age: 25 * 60)) == "stale · 25 min · Kobe")
        #expect(SnapshotRules.metaText(.unknown) == "never updated")
    }

    @Test func scheduleTable() {
        #expect(SnapshotRules.schedule(for: .now) == 300)
        #expect(SnapshotRules.schedule(for: .whatsapp) == 120)
        #expect(SnapshotRules.schedule(for: .google) == 3600)
        #expect(SnapshotRules.schedule(for: .work) == 60)
        #expect(SnapshotRules.schedule(for: .stripe) == 600)
        #expect(SnapshotRules.schedule(for: .notes) == 900)
        // The Mac connectors: Mail polls while Mail runs; Agenda and Reminders rewrite on change and at boundaries,
        // with an hourly heartbeat, so they are stale only when the app stopped.
        #expect(SnapshotRules.schedule(for: .mail) == 300)
        #expect(SnapshotRules.schedule(for: .agenda) == 3600)
        #expect(SnapshotRules.schedule(for: .reminders) == 3600)
    }

    @Test func writeAtomicallyLeavesNoTempFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kobe-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("widgets/stripe.json")
        try SnapshotFolder.writeAtomically(Data("{}".utf8), to: file, shared: true)
        try SnapshotFolder.writeAtomically(Data("{\"a\":1}".utf8), to: file, shared: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(names == ["stripe.json"])
        #expect(try Data(contentsOf: file) == Data("{\"a\":1}".utf8))
        func mode(_ u: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
        #expect(try mode(file) == 0o660)
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kobe-snap-\(UUID().uuidString)")
    }

    private func mode(_ u: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue
    }

    @Test func writeKeepsMode0660OverAnExisting0600File() throws {
        let dir = tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("widgets/stripe.json")
        try SnapshotFolder.writeAtomically(Data("{}".utf8), to: file, shared: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try SnapshotFolder.writeAtomically(Data("{\"b\":2}".utf8), to: file, shared: true)
        #expect(try mode(file) == 0o660)
    }

    @Test func foldersAre2770() throws {
        let dir = tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("widgets/stripe.json")
        try SnapshotFolder.writeAtomically(Data("{}".utf8), to: file, shared: true)
        #expect(try mode(file.deletingLastPathComponent()) == 0o2770)
        // An older 0750 folder of ours is repaired.
        let results = dir.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o750])
        SnapshotFolder.prepare(results, shared: true)
        #expect(try mode(results) == 0o2770)
    }

    @Test func decodesFractionalSeconds() throws {
        let json = #"{"id":"vercel","version":1,"updated_at":"2026-10-23T14:28:10.250Z","status":"ok","headline":"","detail":"","error":null,"data":{}}"#
        let snap = try #require(SnapshotDecode.decode(Data(json.utf8), as: EmptyData.self))
        #expect(snap.updatedAt == Date(timeIntervalSince1970: 1_792_765_690.25))
    }

    @Test func unknownStatusBecomesFailed() throws {
        let json = #"{"id":"vercel","version":1,"updated_at":"2026-10-23T14:28:10Z","status":"melting","headline":"h","detail":"d","error":null,"data":{}}"#
        let snap = try #require(SnapshotDecode.decode(Data(json.utf8), as: EmptyData.self))
        #expect(snap.status == .failed)
        #expect(snap.error == "Unknown status melting")
        let row = #"{"id":"n1","source":"github","title":"t","detail":"d","action":"teleport"}"#
        #expect(try JSONDecoder().decode(NowRow.self, from: Data(row.utf8)).action == .open)
    }

    @Test func missingSourceIsApp() throws {
        let snap = try #require(SnapshotDecode.decode(fixture("stripe"), as: StripeSnapshotData.self))
        #expect(snap.source == .app)
        let agent = WidgetSnapshot(id: .stripe, updatedAt: Date(timeIntervalSince1970: 0), status: .ok, headline: "",
                                   detail: "", data: EmptyData(), source: .agent)
        let json = try SnapshotEncode.encode(agent)
        #expect(String(decoding: json, as: UTF8.self).contains(#""source":"agent""#))
        #expect(SnapshotDecode.decode(json, as: EmptyData.self)?.source == .agent)
    }

    @Test func defaultFolderIsUnderApplicationSupport() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kobe/exchange").path
        let settings = ExchangeSettings(folder: expected, shared: false)
        #expect(SnapshotFolder.root(for: settings, environment: [:]).path == expected)
    }

    @Test func envOverrideWins() {
        let settings = ExchangeSettings(folder: "/tmp/kobe-setting", shared: false)
        let root = SnapshotFolder.root(for: settings, environment: ["KOBE_EXCHANGE_ROOT": "/tmp/kobe-x"])
        #expect(root.path == "/tmp/kobe-x")
        #expect(SnapshotFolder.root(for: settings, environment: ["KOBE_EXCHANGE_ROOT": ""]).path == "/tmp/kobe-setting")
    }

    @Test func configuredRootDrivesEveryPath() {
        let before = SnapshotFolder.settings
        defer { SnapshotFolder.configure(before) }
        unsetenv("KOBE_EXCHANGE_ROOT")
        SnapshotFolder.configure(ExchangeSettings(folder: "/tmp/kobe-cfg", shared: false))
        #expect(SnapshotFolder.url(.stripe).path == "/tmp/kobe-cfg/widgets/stripe.json")
        #expect(SnapshotFolder.requests.path == "/tmp/kobe-cfg/requests")
        #expect(SnapshotFolder.results.path == "/tmp/kobe-cfg/results")
        #expect(!SnapshotFolder.shared)
    }

    @Test func sameUserWritesPlainModes() throws {
        let dir = tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("widgets/stripe.json")
        try SnapshotFolder.writeAtomically(Data("{}".utf8), to: file, shared: false)
        #expect(try mode(file) == 0o644)
        #expect(try mode(file.deletingLastPathComponent()) == 0o755)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value == getgid())
    }

    @Test func sharedModeKeepsGroupWrite() throws {
        let dir = tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("widgets/stripe.json")
        try SnapshotFolder.writeAtomically(Data("{}".utf8), to: file, shared: true)
        #expect(try mode(file) == 0o660)
        #expect(try mode(file.deletingLastPathComponent()) == 0o2770)
    }

    @Test func urlInAGivenRootIgnoresTheEnvironment() {
        // An injected root (the app's tests, one temp folder each) never reads the process-wide setting.
        let root = URL(fileURLWithPath: "/tmp/kobe-given")
        #expect(SnapshotFolder.widgets(in: root).path == "/tmp/kobe-given/widgets")
        #expect(SnapshotFolder.url(.vercel, in: root).path == "/tmp/kobe-given/widgets/vercel.json")
    }

    @Test func emptyDataRoundTrips() throws {
        let snap = WidgetSnapshot(id: .google, updatedAt: Date(timeIntervalSince1970: 0), status: .notSetUp,
                                  headline: "Not set up", detail: "", data: EmptyData())
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(snap)
        #expect(String(decoding: json, as: UTF8.self).contains("not_set_up"))
        #expect(SnapshotDecode.decode(json, as: EmptyData.self) == snap)
    }

    // MARK: The Mac connectors' snapshots (Mail, Agenda, Reminders, Notes)

    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func decodesMail() throws {
        let s = try #require(SnapshotDecode.decode(fixture("mail"), as: MailSnapshotData.self))
        #expect(s.id == .mail && s.source == .app)
        #expect(s.data.unread == 2 && s.data.appRunning && s.data.messages.count == 3)
        let m = s.data.messages[0]
        #expect(m.id == "CAF=abc@mail.gmail.com")
        #expect(m.sender == "Example Client" && m.subject == "Menu for Saturday")
        #expect(m.preview == "Hi, could we add two dishes before the weekend?")
        #expect(m.at == iso("2026-10-24T13:50:00Z") && m.unread && m.account == "Google")
        #expect(!s.data.messages[2].unread)
    }

    @Test func decodesAgenda() throws {
        let s = try #require(SnapshotDecode.decode(fixture("agenda"), as: AgendaSnapshotData.self))
        #expect(s.data.from == iso("2026-10-23T00:00:00Z") && s.data.to == iso("2026-11-24T00:00:00Z"))
        #expect(s.data.calendars[0] == AgendaCalendar(id: "cal-work", name: "Work", color: "#F4505E"))
        let e = s.data.events[0]
        #expect(e.id == "ev-1" && e.title == "Call with Example Client" && e.calendar == "cal-work")
        #expect(e.start == iso("2026-10-24T15:00:00Z") && e.end == iso("2026-10-24T15:30:00Z") && !e.allDay)
        #expect(e.location == "Zoom" && e.url == "https://example.com/meet/1" && e.notes == "Bring the menu draft.")
        #expect(s.data.events[1].allDay && s.data.events[1].location == nil && s.data.events[1].notes == nil)
    }

    @Test func decodesReminders() throws {
        let s = try #require(SnapshotDecode.decode(fixture("reminders"), as: RemindersSnapshotData.self))
        #expect(s.status == .needsYou && s.data.overdue == 1)
        let r = s.data.reminders[0]
        #expect(r.id == "rem-1" && r.title == "Send the invoice" && r.list == "Work" && r.listColor == "#F5A524")
        #expect(r.due == iso("2026-10-23T09:00:00Z") && r.dueHasTime && !r.completed && r.notes == "For October.")
        #expect(!s.data.reminders[1].dueHasTime)
        #expect(s.data.reminders[2].due == nil)
    }

    @Test func decodesNotes() throws {
        let s = try #require(SnapshotDecode.decode(fixture("notes"), as: NotesSnapshotData.self))
        #expect(!s.data.appRunning && s.data.notes.count == 2)
        let n = s.data.notes[0]
        #expect(n.id == "x-coredata://ABC/ICNote/p12" && n.title == "Menu ideas")
        #expect(n.snippet == "Tacos al pastor\nAgua de jamaica\nFlan" && n.folder == "Notes")
        #expect(n.modified == iso("2026-10-24T12:00:00Z"))
    }

    @Test func macSnapshotsRoundTrip() throws {
        func trip<D: Codable & Sendable & Equatable>(_ name: String, _ type: D.Type) throws {
            let s = try #require(SnapshotDecode.decode(fixture(name), as: D.self))
            let back = try #require(SnapshotDecode.decode(try SnapshotEncode.encode(s), as: D.self))
            #expect(back == s)
        }
        try trip("mail", MailSnapshotData.self)
        try trip("agenda", AgendaSnapshotData.self)
        try trip("reminders", RemindersSnapshotData.self)
        try trip("notes", NotesSnapshotData.self)
    }
}
