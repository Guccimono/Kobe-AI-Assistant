import Foundation
import Testing
@testable import KobeApp
@testable import KobeKit

@MainActor
struct AppModelTests {
    @Test func replyNoticeFiresAfterATurn() async {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        model.startTracking()
        #expect(model.replyNotice == nil)
        model.send("Summarise the brief")
        // The band waits for the turn to be over: never while Kobe is still answering.
        #expect(await TestApp.eventually { model.chats.lastReply != nil && !model.isBusy })
        #expect(await TestApp.eventually { model.replyNotice != nil })
        #expect(model.replyNotice == "Hello")
        #expect(model.banner?.title == "Kobe replied")
    }

    @Test func badgeSetWhenCardClosedNotWhenOpen() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let event = ServiceEvent(pill: "stripe", kind: .error, detail: "Payment failed", sound: .silent)
        model.report(event)
        #expect(model.serviceBadges[.stripe] == .error)
        #expect(model.serviceNotice == event)

        model.serviceBadges = [:]
        model.serviceNotice = nil
        model.island.phase = .expanded
        model.island.overlay = .page(.stripe)
        model.report(event)
        // Its page is on screen: no badge and no band, the page shows it already.
        #expect(model.serviceBadges[.stripe] == nil)
        #expect(model.serviceNotice == nil)
    }

    @Test func openPageClearsBadge() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        model.serviceBadges = [.github: .attention, .vercel: .error]
        model.openPage(.github)
        #expect(model.serviceBadges[.github] == nil)
        #expect(model.serviceBadges[.vercel] == .error)
    }

    @Test func dropsUseTheSameRoot() throws {
        let folder = TestSnapshotFolder()
        let (model, cleanup) = TestApp.model(folder: folder)
        defer { cleanup(); folder.remove() }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("kobe-drop-src-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(model.dropFiles([source]))
        let inbox = folder.root.appendingPathComponent("inbox")
        let days = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
        #expect(days.count == 1)
        let landed = try FileManager.default.contentsOfDirectory(atPath: inbox.appendingPathComponent(days[0]).path)
        #expect(landed == [source.lastPathComponent])
    }

    @Test func nowPaneFallsBackToRankerWhenNoSnapshot() throws {
        let folder = TestSnapshotFolder()
        let vercel = WidgetSnapshot(id: .vercel, updatedAt: .now, status: .ok, headline: "", detail: "",
                                    data: VercelSnapshotData(projects: [
                                        VercelSnapshotProject(name: "menuly", state: "error", branch: "main", commit: "Fix menu",
                                                              at: .now, url: "https://menuly.vercel.app", isProduction: true),
                                    ]))
        try folder.write(vercel)
        let (model, cleanup) = TestApp.model(folder: folder)
        defer { cleanup() }
        model.snapshots.start()
        defer { model.snapshots.stop() }
        // No now.json: Home's Now is the shim's ranked list, dated by its newest input.
        #expect(model.snapshots.now == nil)
        #expect(model.snapshots.vercel != nil)
        let (data, updatedAt) = model.nowContent
        #expect(data.needsYou.map(\.id) == ["vercel:menuly"])
        #expect(updatedAt == model.snapshots.vercel?.updatedAt)
    }

    // MARK: The Allow hotkey's lock

    @Test func approvalAllowLockedUntilACardShowsTheWholeCommand() async {
        let api = FakeHermes()
        let (model, cleanup) = TestApp.model(api: api)
        defer { cleanup() }
        #expect(await TestApp.approvalWaiting(model, api: api))
        model.island.phase = .expanded
        model.island.overlay = .none
        model.arm()
        // No card has reported yet: nothing on screen can be allowed by hotkey.
        #expect(model.approvalAllowLocked)
        let card = UUID()
        model.reportApprovalLock(card, locked: false)
        #expect(!model.approvalAllowLocked)
        // The card went (⌘\, a page change, the notch folding): fail safe, locked again.
        model.reportApprovalLock(card, locked: nil)
        #expect(model.approvalAllowLocked)
        try? await Task.sleep(for: .seconds(0.35))
        model.hotKey(allow: true)
        #expect(model.approvalsToday == 0)
        #expect(model.chats.pendingApproval != nil)
        // A card on screen with its end seen: the hotkey allows.
        model.reportApprovalLock(card, locked: false)
        model.hotKey(allow: true)
        #expect(model.approvalsToday == 1)
    }

    @Test func claudeAllowLockedWithoutACardOnScreen() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        #expect(model.claudeAllowLocked)
        let shown = UUID(), leaving = UUID()
        model.reportClaudeLock(shown, locked: false)
        #expect(!model.claudeAllowLocked)
        // Two cards on screen during a transition: one still locked keeps the hotkey locked.
        model.reportClaudeLock(leaving, locked: true)
        #expect(model.claudeAllowLocked)
        model.reportClaudeLock(leaving, locked: nil)
        #expect(!model.claudeAllowLocked)
        model.reportClaudeLock(shown, locked: nil)
        #expect(model.claudeAllowLocked)
    }
}

@MainActor
struct TestSandboxTests {
    @Test func cleanupRemovesTheDefaultsSuiteAndTheFolder() async {
        let sandbox = TestSandbox()
        let defaults = UserDefaults(suiteName: sandbox.suiteName)!
        defaults.set(true, forKey: "written")
        #expect(FileManager.default.fileExists(atPath: sandbox.folder.root.path))
        sandbox.cleanup()
        #expect(UserDefaults(suiteName: sandbox.suiteName)!.object(forKey: "written") == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.folder.root.path))
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(sandbox.suiteName).plist").path
        #expect(await TestApp.eventually { !FileManager.default.fileExists(atPath: plist) })
    }
}

// MARK: Refresh through Kobe Agent (plan 2)

@MainActor
struct AgentRefreshTests {
    private func requests(_ folder: TestSnapshotFolder) -> [URL] {
        let dir = folder.root.appendingPathComponent("requests")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
    }

    private func refusal(_ result: Result<Void, ActionError>) -> String? {
        if case .failure(let error) = result { return error.message }
        return nil
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func refreshGoesThroughAgentWhenItOwnsTheConnector() async throws {
        let folder = TestSnapshotFolder()
        try folder.write(WidgetSnapshot(id: .stripe, updatedAt: .now, status: .ok, headline: "", detail: "",
                                        data: StripeSnapshotData(period: "today", total: 0, count: 0, failed: 0, refunds: 0, currency: "eur",
                                                           available: 0, pending: 0, nextPayout: nil, payments: []), source: .agent))
        let (model, cleanup) = TestApp.model(folder: folder)
        defer { cleanup() }
        model.snapshots.start()
        defer { model.snapshots.stop() }
        #expect(model.owner(.stripe) == .agent)
        model.refreshPage(.stripe)
        #expect(await eventually { requests(folder).count == 1 })
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: try #require(requests(folder).first)))
        #expect(body as? [String: String] == ["action": "refresh", "id": "stripe"])
    }

    @Test func refreshUsesTheShimOtherwise() async throws {
        let folder = TestSnapshotFolder()
        try folder.write(WidgetSnapshot(id: .stripe, updatedAt: .now, status: .ok, headline: "", detail: "",
                                        data: StripeSnapshotData(period: "today", total: 0, count: 0, failed: 0, refunds: 0, currency: "eur",
                                                           available: 0, pending: 0, nextPayout: nil, payments: [])))
        let (model, cleanup) = TestApp.model(folder: folder)
        defer { cleanup() }
        model.snapshots.start()
        defer { model.snapshots.stop() }
        #expect(model.owner(.stripe) == .app)
        model.refreshPage(.stripe)
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests(folder).isEmpty)
    }

    @Test func googleRefreshesOnlyThroughTheAgent() async throws {
        let folder = TestSnapshotFolder()
        let (model, cleanup) = TestApp.model(folder: folder)
        defer { cleanup() }
        #expect(!model.canRefresh(.google))
        try folder.write(WidgetSnapshot(id: .google, updatedAt: .now, status: .ok, headline: "", detail: "",
                                        data: GoogleSnapshotData(
                                            periodDays: 7, visitors: 1, visitorsPrev: 1, clicks: 1, clicksPrev: 1,
                                            position: 1, positionPrev: 1, calls: nil, callsPrev: nil, topQueries: [],
                                            dailyClicks: [], businessProfile: "waiting_access",
                                            reportUrls: GoogleReportURLs(analytics: "", search: "")),
                                        source: .agent))
        #expect(model.snapshots.google == nil)
        model.snapshots.start()
        defer { model.snapshots.stop() }
        #expect(model.canRefresh(.google))
        #expect(model.snapshots.google?.data.periodDays == 7)
    }

    @Test func staleGoogleStillRefreshesThroughTheAgent() async throws {
        // After a night asleep the agent's Google file is stale: ↻ is exactly what's needed then.
        let folder = TestSnapshotFolder()
        try folder.write(WidgetSnapshot(id: .google, updatedAt: .now - 4 * 3600, status: .ok, headline: "", detail: "",
                                        data: GoogleSnapshotData(
                                            periodDays: 7, visitors: 1, visitorsPrev: 1, clicks: 1, clicksPrev: 1,
                                            position: 1, positionPrev: 1, calls: nil, callsPrev: nil, topQueries: [],
                                            dailyClicks: [], businessProfile: "waiting_access",
                                            reportUrls: GoogleReportURLs(analytics: "", search: "")),
                                        source: .agent))
        let (model, cleanup) = TestApp.model(folder: folder)
        defer { cleanup() }
        model.snapshots.start()
        defer { model.snapshots.stop() }
        #expect(model.owner(.google) == .app)
        #expect(model.canRefresh(.google))
        model.refreshPage(.google)
        #expect(await eventually { requests(folder).count == 1 })
    }

    @Test func requestSinkMapsTheAgentsAnswer() async throws {
        let folder = TestSnapshotFolder()
        defer { folder.remove() }
        let sink = RequestFileActionSink(root: folder.root, timeout: .seconds(5))
        let pending = Task { await sink.perform(.refresh(.whatsapp)) }
        #expect(await eventually { requests(folder).count == 1 })
        let name = try #require(requests(folder).first).lastPathComponent
        try SnapshotFolder.writeAtomically(
            Data(#"{"id":"x","ok":false,"error":"Kobe Agent doesn't run whatsapp yet","done_at":"2026-10-24T12:00:00Z"}"#.utf8),
            to: folder.root.appendingPathComponent("results/\(name)"))
        #expect(refusal(await pending.value) == "Kobe Agent doesn't run whatsapp yet")
        // The answer is read once and cleared.
        #expect(!FileManager.default.fileExists(atPath: folder.root.appendingPathComponent("results/\(name)").path))
    }

    @Test func requestSinkGivesUpAndWithdrawsTheRequest() async {
        let folder = TestSnapshotFolder()
        defer { folder.remove() }
        let sink = RequestFileActionSink(root: folder.root, timeout: .milliseconds(300))
        #expect(refusal(await sink.perform(.refresh(.stripe))) == "Kobe Agent didn't answer")
        #expect(requests(folder).isEmpty)
        #expect(refusal(await sink.perform(.whatsappMarkRead(chat: "x"))) == "Kobe Agent doesn't do that yet")
    }

    // MARK: The Mac pages

    @Test func macPagesRefreshThroughTheController() async {
        let calendar = FakeCalendar()
        calendar.accessByKind[.reminders] = .granted
        let (model, cleanup) = TestApp.model(calendar: calendar)
        defer { cleanup() }
        #expect(!model.canRefresh(.mail) && !model.canRefresh(.reminders))
        model.settings.mailOn = true
        model.settings.remindersOn = true
        #expect(model.canRefresh(.mail) && model.canRefresh(.reminders))
        model.refreshPage(.reminders)
        #expect(await TestApp.eventually { calendar.reminderReads == 1 })
        model.mac.stop()
    }

    @Test func reminderTickReachesReminders() async {
        let calendar = FakeCalendar()
        calendar.accessByKind[.reminders] = .granted
        calendar.reminderList = [ReminderItem(id: "r1", title: "Invoice", list: "Work", listColor: "#F5A524", due: nil,
                                              dueHasTime: false, completed: false)]
        let (model, cleanup) = TestApp.model(calendar: calendar)
        defer { cleanup() }
        model.settings.remindersOn = true
        let result = await model.actions.perform(.reminderDone(id: "r1", done: true))
        if case .failure = result { Issue.record("the tick was refused") }
        #expect(calendar.reminderList[0].completed)
        _ = await model.actions.perform(.reminderDone(id: "r1", done: false))
        #expect(!calendar.reminderList[0].completed)
        model.mac.stop()
    }

    @Test func addReminderGoesThroughTheSink() async {
        let calendar = FakeCalendar()
        calendar.accessByKind[.reminders] = .granted
        let (model, cleanup) = TestApp.model(calendar: calendar)
        defer { cleanup() }
        model.settings.remindersOn = true
        let draft = ReminderDraft(title: "Buy limes", due: nil, dueHasTime: false)
        let result = await model.actions.perform(.addReminder(draft, list: nil))
        if case .failure = result { Issue.record("the add was refused") }
        #expect(calendar.added.map(\.draft) == [draft])
        model.mac.stop()
    }
}

// MARK: Settings › Engine, Your assistant, Set up again

@MainActor
struct SettingsEngineTests {
    static let config = "/fake/home/.hermes/config.yaml"
    static let soul = "/fake/home/.hermes/SOUL.md"
    static let profile = "/fake/home/.hermes/kobe/profile.md"

    @Test func rotateKeyWritesConfigAndKeychain() async {
        let shell = FakeShell()
        shell.setFile("/fake/home/.local/bin/hermes", "")
        let stub = StubHTTP.make { _ in 503 }
        let (model, cleanup) = TestApp.model(shell: shell, session: stub.session)
        defer { cleanup() }
        model.settings.serverURL = stub.base.absoluteString
        #expect(!model.key.isSet)
        let message = await model.rotateEngineKey(healthTimeout: .milliseconds(10))
        #expect(message == "The engine didn't answer with the new key in time. Press Check in a moment.")
        #expect(shell.files[Self.config]?.contains("key:") == true)
        #expect(model.key.isSet)
        #expect(model.settings.onboarding.finishedFromSettings)
        #expect(shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) })
    }

    @Test func rotateLeavesAGatewayOutsideKobeAlone() async {
        let shell = FakeShell()
        shell.setFile("/fake/home/.local/bin/hermes", "")
        let keyed = "gateway:\n  api_server:\n    enabled: true\n    host: 127.0.0.1\n    port: 8642\n    key: theirs\n"
        shell.setFile(Self.config, keyed)
        shell.script(["launchctl", "print"], status: 113)
        let stub = StubHTTP.make { _ in 200 }
        let (model, cleanup) = TestApp.model(shell: shell, session: stub.session)
        defer { cleanup() }
        model.settings.serverURL = stub.base.absoluteString
        let message = await model.rotateEngineKey(healthTimeout: .milliseconds(10))
        #expect(message == EngineService.foreignGatewayMessage)
        #expect(shell.files[Self.config] == keyed)
        #expect(!model.key.isSet)
        #expect(!shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) })
    }

    @Test func anotherUsersEngineIsNeitherRotatedNorTurnedOn() async {
        let shell = FakeShell()
        shell.setFile("/fake/home/.local/bin/hermes", "")
        let stub = StubHTTP.make { _ in 503 }
        let (model, cleanup) = TestApp.model(shell: shell, session: stub.session)
        defer { cleanup() }
        model.settings.serverURL = stub.base.absoluteString
        model.settings.engineSeparateUser = true
        #expect(await model.rotateEngineKey(healthTimeout: .milliseconds(10)) == EngineService.elsewhereMessage)
        await model.engine.turnOn()
        #expect(model.engine.problem == EngineService.elsewhereMessage)
        #expect(shell.files.keys.allSatisfy { !$0.hasPrefix("/fake/home/.hermes") && !$0.contains("LaunchAgents") })
        #expect(!shell.calls.contains { $0.first == "launchctl" })
    }

    // I5: a service key saved or removed in Settings reaches Kobe Agent's secrets right away.
    @Test func serviceKeysReachTheAgentsSecrets() async {
        let shell = FakeShell()
        try? shell.mkdir("/fake/home/.hermes/kobe")
        let (model, cleanup) = TestApp.model(shell: shell)
        defer { cleanup() }
        let path = "/fake/home/.hermes/kobe/secrets/github"
        #expect(await model.saveServiceKey("ghp_secretvalue", for: .github))
        #expect(shell.files[path] == "ghp_secretvalue")
        #expect(shell.modes[path] == 0o600)
        #expect(!shell.argvContains("ghp_secretvalue"))
        await model.removeServiceKey(.github)
        #expect(shell.files[path] == nil)
        #expect(!model.keys.isSet(.github))
    }

    @Test func noAgentNoSecretsFolder() async {
        let shell = FakeShell()
        let (model, cleanup) = TestApp.model(shell: shell)
        defer { cleanup() }
        #expect(await model.saveServiceKey("ghp_secretvalue", for: .github))
        #expect(shell.files.isEmpty)
        #expect(model.keys.load(.github) == "ghp_secretvalue")
    }

    // I4: a port typed in onboarding reaches the hello and the chats without a restart.
    @Test func theClientFollowsTheServerSetting() async {
        let a = StubHTTP.make { _ in 200 }
        let b = StubHTTP.make { _ in 200 }
        let (model, cleanup) = TestApp.model(session: a.session)
        defer { cleanup() }
        model.key.save("k")
        model.settings.serverURL = a.base.absoluteString
        _ = try? await model.client.health()
        model.settings.serverURL = b.base.absoluteString
        _ = try? await model.client.health()
        #expect(StubHTTP.requests(a.host).count == 1)
        #expect(StubHTTP.requests(b.host).count == 1)
    }

    // I2: without Kobe's SOUL.md, every new chat carries the profile as its system prompt.
    @Test func newChatsCarryTheProfileUnlessSoulHasIt() async {
        let api = FakeHermes()
        let (model, cleanup) = TestApp.model(api: api)
        defer { cleanup() }
        model.settings.assistantName = "Ada"
        model.settings.assistantRole = "Runs my café"
        #expect(!model.settings.profileInSoul)
        model.send("Hi")
        #expect(await TestApp.eventually { api.createdSystemPrompts.count == 1 })
        let expected = ProfileFiles.systemPrompt(Profile(name: "Ada", role: "Runs my café", tone: model.settings.assistantTone))
        #expect(api.createdSystemPrompts.first == .some(expected))
        _ = await TestApp.eventually { !model.chats.isBusy }

        model.newChat()
        model.settings.profileInSoul = true
        model.send("Again")
        #expect(await TestApp.eventually { api.createdSystemPrompts.count == 2 })
        #expect(api.createdSystemPrompts.last == .some(nil))
        _ = await TestApp.eventually { !model.chats.isBusy }

        model.settings.profileInSoul = false
        model.quickAsk("Quick one")
        #expect(await TestApp.eventually { api.createdSystemPrompts.count == 3 })
        #expect(api.createdSystemPrompts.last == .some(expected))
    }

    // Another user's Hermes keeps its own SOUL.md: Kobe injects no profile, whatever profileInSoul says.
    @Test func anotherUsersEngineGetsNoSystemPrompt() async {
        let api = FakeHermes()
        let (model, cleanup) = TestApp.model(api: api)
        defer { cleanup() }
        model.settings.engineSeparateUser = true
        model.settings.profileInSoul = false
        model.send("Hi")
        #expect(await TestApp.eventually { api.createdSystemPrompts.count == 1 })
        #expect(api.createdSystemPrompts.first == .some(nil))
        _ = await TestApp.eventually { !model.chats.isBusy }
        model.quickAsk("Quick one")
        #expect(await TestApp.eventually { api.createdSystemPrompts.count == 2 })
        #expect(api.createdSystemPrompts.last == .some(nil))
    }

    @Test func profileChangeRewritesSoulOnlyWhenMarked() async {
        let marked = FakeShell()
        marked.setFile(Self.soul, ProfileFiles.marker + "\nold\n")
        let (a, cleanA) = TestApp.model(shell: marked)
        defer { cleanA() }
        a.settings.assistantRole = "Runs my café"
        #expect(await a.rewriteProfile() == nil)
        #expect(marked.files[Self.soul]?.contains("Runs my café") == true)
        #expect(marked.files[Self.profile]?.contains("Runs my café") == true)

        let foreign = FakeShell()
        foreign.setFile(Self.soul, "My own soul.\n")
        let (b, cleanB) = TestApp.model(shell: foreign)
        defer { cleanB() }
        b.settings.assistantRole = "Runs my café"
        #expect(await b.rewriteProfile() == nil)
        #expect(foreign.files[Self.soul] == "My own soul.\n")
        #expect(foreign.files[Self.profile]?.contains("Runs my café") == true)
    }

    @Test func exchangeToggleRepointsDropsAndSnapshots() async throws {
        let a = TestSnapshotFolder(), b = TestSnapshotFolder()
        let sandbox = TestSandbox(folder: a)
        defer { sandbox.cleanup(); b.remove() }
        let settings = TestApp.settings(suiteName: sandbox.suiteName)
        settings.exchangeFolder = a.root.path
        let model = AppModel(settings: settings, secrets: InMemorySecrets(), api: FakeHermes(), shell: FakeShell(),
                             home: URL(fileURLWithPath: "/fake/home"))
        model.snapshots.start()
        defer { model.snapshots.stop() }
        #expect(model.exchangeRoot.path == a.root.path)
        settings.exchangeFolder = b.root.path
        settings.engineSeparateUser = true
        model.applyExchangeSettings()
        #expect(model.exchangeRoot.path == b.root.path)

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("kobe-drop-src-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(model.dropFiles([source]))
        #expect(FileManager.default.fileExists(atPath: b.root.appendingPathComponent("inbox").path))
        #expect(!FileManager.default.fileExists(atPath: a.root.appendingPathComponent("inbox").path))

        try b.write(WidgetSnapshot(id: .stripe, updatedAt: .now, status: .ok, headline: "new root", detail: "",
                                   data: StripeSnapshotData(period: "today", total: 0, count: 0, failed: 0, refunds: 0, currency: "eur",
                                                            available: 0, pending: 0, nextPayout: nil, payments: []), source: .agent))
        // SnapshotFolder is process-global and other tests' models reconfigure it: restart right before reading.
        model.applyExchangeSettings()
        #expect(model.snapshots.envelopes[.stripe]?.headline == "new root")
    }

    @Test func setUpAgainResetsProgress() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        model.settings.onboarding = OnboardingProgress(completed: [.welcome, .engine], finishedFromSettings: true, done: true)
        model.resetOnboarding()
        #expect(model.settings.onboarding == OnboardingProgress())
        model.finishOnboardingFromSettings()
        #expect(model.settings.onboarding.finishedFromSettings)
    }

    // MARK: Chat polish wiring

    /// Two app models on one private defaults suite: the second is "the next launch".
    private func twoLaunches() -> (first: AppModel, second: () -> AppModel, cleanup: () -> Void) {
        let folder = TestSnapshotFolder()
        let sandbox = TestSandbox(folder: folder)
        func make() -> AppModel {
            AppModel(settings: TestApp.settings(suiteName: sandbox.suiteName), secrets: InMemorySecrets(), api: FakeHermes(),
                     snapshotRoot: folder.root, calendar: FakeCalendar(), scripts: FakeScripts(), shell: FakeShell(),
                     home: URL(fileURLWithPath: "/fake/home"))
        }
        let first = make()
        return (first, make, sandbox.cleanup)
    }

    @Test func draftSurvivesARelaunch() {
        let (first, second, cleanup) = twoLaunches()
        defer { cleanup() }
        first.composerDraft = "half a thought"
        #expect(second().composerDraft == "half a thought")
    }

    @Test func keyLikeDraftIsNotPersisted() {
        let (first, second, cleanup) = twoLaunches()
        defer { cleanup() }
        first.composerDraft = "sk-abc123"
        #expect(first.composerDraft == "sk-abc123")
        #expect(second().composerDraft == "")
    }

    @Test func headerShowsTheToolStatusOnlyWhenReachableAndFree() {
        func t(_ status: String?, _ needs: Bool, _ connected: Bool) -> String {
            ChatView.headerText(status: status, needsAnswer: needs, connected: connected, base: "base")
        }
        #expect(t("searching the web…", false, true) == "searching the web…")
        #expect(t("searching the web…", true, true) == "base")
        #expect(t("searching the web…", false, false) == "base")
        #expect(t(nil, false, true) == "base")
    }

    @Test func editingADraftIntoAKeyForgetsIt() {
        let (first, second, cleanup) = twoLaunches()
        defer { cleanup() }
        first.composerDraft = "half a thought"
        first.composerDraft = "sk_live_abc123"
        #expect(second().composerDraft == "")
    }

    @Test func returnHintCountsSends() async {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        #expect(model.settings.returnHintsShown == 0)
        for n in 1...4 {
            model.send("hello \(n)")
            #expect(await TestApp.eventually { model.settings.returnHintsShown == n && !model.isBusy })
        }
        // It counts every successful send; the view only shows the hint while the count is under 3.
        #expect(model.settings.returnHintsShown == 4)
    }

    @Test func editLastMessagePutsTextInTheComposer() async {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        model.send("Summarise the brief")
        #expect(await TestApp.eventually { model.chats.lastReply != nil && !model.isBusy })
        model.composerDraft = ""
        model.editLastMessage()
        #expect(model.composerDraft == "Summarise the brief")
        #expect(model.composerFocusPending)
    }
}
