import Foundation
import Testing
@testable import KobeApp
@testable import KobeKit

@MainActor
struct ConnectServiceTests {
    static let home = URL(fileURLWithPath: "/fake/home")
    static let source = URL(fileURLWithPath: "/fake/agent")
    static let config = "/fake/home/.hermes/config.yaml"
    static let soul = "/fake/home/.hermes/SOUL.md"
    static let profile = "/fake/home/.hermes/kobe/profile.md"
    static let keyed = "gateway:\n  api_server:\n    enabled: true\n    host: 127.0.0.1\n    port: 8642\n    key: old-key\n"

    struct Rig {
        let service: ConnectService
        let app: AppModel
        let shell: FakeShell
        let api: FakeHermes
        let cleanup: () -> Void
    }

    func rig(withSkill: Bool = true, detailed: Int = 200) -> Rig {
        let api = FakeHermes()
        let (app, cleanupApp) = TestApp.model(api: api)
        let stub = StubHTTP.make { $0.url?.path.hasSuffix("detailed") == true ? detailed : 200 }
        app.settings.serverURL = stub.base.absoluteString
        let shell = FakeShell()
        shell.setFile("/fake/home/.local/bin/hermes", "")
        if withSkill { try? shell.mkdir(Self.source.path) }
        let secrets = InMemorySecrets()
        let brain = BrainService(settings: app.settings, shell: shell, secrets: secrets, home: Self.home)
        brain.store(brain: .claude, key: "sk-ant-test")
        let engine = EngineService(settings: app.settings, shell: shell, key: app.key, session: stub.session, home: Self.home)
        let service = ConnectService(app: app, engine: engine, brain: brain, shell: shell, home: Self.home,
                                     agentSource: withSkill ? Self.source : nil)
        return Rig(service: service, app: app, shell: shell, api: api, cleanup: cleanupApp)
    }

    private func index(_ calls: [[String]], where match: ([String]) -> Bool) -> Int? { calls.firstIndex(where: match) }

    @Test func linesTickInOrder() async {
        let r = rig()
        defer { r.cleanup() }
        #expect(ConnectLine.allCases.allSatisfy { r.service.lines[$0] == .pending })
        await r.service.run(choice: nil)
        #expect(ConnectLine.allCases.allSatisfy { r.service.lines[$0] == .done })
        let calls = r.shell.calls
        let brain = index(calls) { $0.starts(with: ["hermes", "config", "set"]) }
        let skill = index(calls) { $0.starts(with: ["rsync"]) }
        let gateway = index(calls) { $0.starts(with: ["launchctl", "bootstrap"]) && $0.last?.contains("gateway") == true }
        #expect(brain != nil && skill != nil && gateway != nil)
        #expect(brain! < skill! && skill! < gateway!)
        #expect(r.shell.files["/fake/home/.hermes/.env"]?.contains("ANTHROPIC_API_KEY") == true)
        #expect(r.shell.files[Self.profile] != nil)
    }

    @Test func keepingHermesBrainTicksLineOneWithoutWriting() async {
        let r = rig()
        defer { r.cleanup() }
        r.app.brainKeptFromHermes = true
        await r.service.run(choice: nil)
        #expect(r.service.lines[.gaveKey] == .done)
        #expect(r.shell.files["/fake/home/.hermes/.env"] == nil)
        #expect(!r.shell.calls.contains { $0.starts(with: ["hermes", "config", "set"]) })
        #expect(r.service.lines[.installedSkill] == .done)
    }

    @Test func changingTheBrainTakesTheNormalPath() async {
        let r = rig()
        defer { r.cleanup() }
        r.app.brainKeptFromHermes = false
        await r.service.run(choice: nil)
        #expect(r.shell.files["/fake/home/.hermes/.env"]?.contains("ANTHROPIC_API_KEY") == true)
        #expect(r.shell.calls.contains { $0.starts(with: ["hermes", "config", "set"]) })
    }

    @Test func stopsForAChoiceWhenHermesHasAKey() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, Self.keyed)
        await r.service.run(choice: nil)
        guard case .needsChoice = r.service.lines[.privateKey] else {
            Issue.record("expected needsChoice, got \(String(describing: r.service.lines[.privateKey]))"); return
        }
        #expect(r.service.lines[.gaveKey] == .done)
        #expect(r.service.lines[.installedSkill] == .done)
        #expect(r.service.lines[.wrotePersonality] == .pending)
        #expect(r.service.lines[.firstHello] == .pending)
        #expect(r.shell.files[Self.config] == Self.keyed)
    }

    @Test func pasteExistingNeverRestarts() async {
        let r = rig(withSkill: false)
        defer { r.cleanup() }
        r.shell.setFile(Self.config, Self.keyed)
        await r.service.run(choice: .pasteExisting("old-key"))
        #expect(r.app.key.load() == "old-key")
        #expect(r.shell.files[Self.config] == Self.keyed)
        #expect(!r.shell.calls.contains { $0.first == "launchctl" })
        #expect(r.service.lines[.privateKey] == .done)
        #expect(r.service.lines[.firstHello] == .done)
    }

    @Test func rotateWritesANewKeyAndRestarts() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, Self.keyed)
        await r.service.run(choice: .rotate)
        #expect(r.shell.files[Self.config]?.contains("old-key") == false)
        #expect(r.app.key.isSet)
        #expect(r.shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) && $0.last?.contains("gateway") == true })
        #expect(r.service.lines[.privateKey] == .done)
    }

    @Test func soulWrittenOnlyWhenAbsentOrMarked() throws {
        let r = rig()
        defer { r.cleanup() }
        r.app.settings.assistantName = "Ada"
        try r.service.writePersonality()
        #expect(r.shell.files[Self.soul]?.hasPrefix(ProfileFiles.marker) == true)
        #expect(r.shell.files[Self.profile]?.contains("name: Ada") == true)
        #expect(r.service.profileAppliedBy == .soul)
        #expect(r.shell.modes[Self.profile] == 0o644)
        // Kobe's own file is rewritten...
        r.app.settings.assistantName = "Bea"
        try r.service.writePersonality()
        #expect(r.shell.files[Self.soul]?.contains("# Bea") == true)
        // ...a file the person made is not.
        r.shell.setFile(Self.soul, "My own soul\n")
        try r.service.writePersonality()
        #expect(r.shell.files[Self.soul] == "My own soul\n")
        #expect(r.shell.files[Self.profile]?.contains("name: Bea") == true)
        #expect(r.service.profileAppliedBy == nil)
        // An unreadable one is not overwritten either.
        r.shell.setFile(Self.soul, ProfileFiles.marker + "\n")
        r.shell.makeUnreadable(Self.soul)
        try r.service.writePersonality()
        #expect(r.shell.files[Self.soul] == ProfileFiles.marker + "\n")
    }

    // Task 12: a SOUL.md that exists but can't be read is left alone, and the profile goes with the session.
    @Test func unreadableSoulIsLeftUntouched() throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.soul, "theirs\n")
        r.shell.makeUnreadable(Self.soul)
        r.app.settings.profileInSoul = true
        try r.service.writePersonality()
        #expect(r.shell.files[Self.soul] == "theirs\n")
        #expect(r.shell.modes[Self.soul] == nil)
        #expect(r.service.profileAppliedBy == nil)
        #expect(!r.app.settings.profileInSoul)
        #expect(r.shell.files[Self.profile] != nil)
    }

    @Test func aBlankNameStillSaysWhoDidntAnswer() async {
        let r = rig()
        defer { r.cleanup() }
        r.app.settings.assistantName = "   "
        r.api.turn = [.started(runID: "r"), .done]
        await r.service.run(choice: nil)
        #expect(r.service.lines[.firstHello] == .failed("Kobe didn't answer."))
    }

    @Test func helloComesFromTheFirstReply() async {
        let r = rig()
        defer { r.cleanup() }
        r.api.turn = [.started(runID: "r"), .completed(content: "\nHi, I'm Kobe.\nCalendar or inbox?", model: nil), .done]
        await r.service.run(choice: nil)
        #expect(r.service.hello == "Hi, I'm Kobe.")
        #expect(r.service.lines[.firstHello] == .done)
    }

    @Test func helloFallsBackWhenTheStreamFails() async {
        let r = rig()
        defer { r.cleanup() }
        r.api.turn = [.started(runID: "r"), .failed("boom"), .done]
        await r.service.run(choice: nil)
        #expect(r.service.hello == ProfileFiles.hello(Profile(name: r.app.settings.assistantName, role: r.app.settings.assistantRole,
                                                              tone: r.app.settings.assistantTone)))
        guard case .failed = r.service.lines[.firstHello] else { Issue.record("expected failed"); return }
    }

    @Test func secretsFileIs0600() async {
        let r = rig()
        defer { r.cleanup() }
        r.app.keys.save("ghp_secretvalue", for: .github)
        await r.service.run(choice: nil)
        let path = "/fake/home/.hermes/kobe/secrets/github"
        #expect(r.shell.files[path] == "ghp_secretvalue")
        #expect(r.shell.modes[path] == 0o600)
        #expect(r.shell.files["/fake/home/.hermes/kobe/secrets/stripe"] == nil)
        #expect(r.shell.calls.contains { $0 == ["chmod", "700", "/fake/home/.hermes/kobe/secrets"] })
        #expect(!r.shell.argvContains("ghp_secretvalue"))
        let json = r.shell.files["/fake/home/.hermes/kobe/config.json"] ?? ""
        #expect(json.contains("exchange_folder") && json.contains("\"version\""))
        let plist = r.shell.files["/fake/home/Library/LaunchAgents/com.kobe-assistant.agent.plist"] ?? ""
        #expect(plist.contains("kobe_agent"))
        let parsed = try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        #expect((parsed?["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(parsed?["ThrottleInterval"] as? Int == 10)
        #expect(r.shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) && $0.last?.hasSuffix("agent.plist") == true })
    }

    @Test func reinstallKeepsTheAgentsOwnConfigKeys() async throws {
        let r = rig()
        defer { r.cleanup() }
        let path = "/fake/home/.hermes/kobe/config.json"
        r.shell.setFile(path, #"{"exchange_folder":"/old","google_property":"42","google_site":"sc-domain:example.org","shared":true,"version":0}"#)
        // The installer itself (a run with the toggle on skips it): `shared` follows the setting.
        r.app.settings.engineSeparateUser = true
        try await r.service.installSkill()
        var json = try #require(JSONSerialization.jsonObject(with: Data((r.shell.files[path] ?? "").utf8)) as? [String: Any])
        #expect(json["google_property"] as? String == "42")
        #expect(json["google_site"] as? String == "sc-domain:example.org")
        #expect(json["shared"] as? Bool == true)
        #expect(json["version"] as? Int == 1)
        #expect(json["exchange_folder"] as? String == r.app.settings.exchangeFolder)
        r.app.settings.engineSeparateUser = false
        try await r.service.installSkill()
        json = try #require(JSONSerialization.jsonObject(with: Data((r.shell.files[path] ?? "").utf8)) as? [String: Any])
        #expect(json["shared"] == nil && json["google_property"] as? String == "42")
    }

    @Test func skillMissingDoesNotStopTheRun() async {
        let r = rig(withSkill: false)
        defer { r.cleanup() }
        await r.service.run(choice: nil)
        #expect(r.service.lines[.installedSkill] == .failed("The Kobe skill isn't in this build"))
        #expect(r.service.lines[.privateKey] == .done)
        #expect(r.service.lines[.wrotePersonality] == .done)
        #expect(r.service.lines[.firstHello] == .done)
    }

    @Test func failedHandOverStopsTheRun() async {
        let r = rig()
        defer { r.cleanup() }
        r.app.settings.selectedBrain = .openai   // no key stored for it
        await r.service.run(choice: nil)
        guard case .failed = r.service.lines[.gaveKey] else { Issue.record("expected failed"); return }
        #expect(r.service.lines[.installedSkill] == .pending)
    }

    // I6: the key is written but the model refused: line 1 fails and the run stops.
    @Test func aRefusedModelFailsLineOne() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.script(["hermes", "config", "set"], status: 1, stderr: "unknown model")
        await r.service.run(choice: nil)
        #expect(r.service.lines[.gaveKey] == .failed("Kobe set the key, but `hermes config set` refused the model: unknown model"))
        #expect(r.service.lines[.installedSkill] == .pending)
        #expect(r.shell.files["/fake/home/.hermes/.env"]?.contains("ANTHROPIC_API_KEY") == true)
    }

    @Test func profileAppliedBySessionWhenSoulExists() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.soul, "My own soul\n")
        r.app.settings.profileInSoul = true
        await r.service.run(choice: nil)
        #expect(r.api.createdSystemPrompts.count == 1)
        #expect(r.api.createdSystemPrompts[0]?.hasPrefix("You are") == true)
        #expect(r.service.profileAppliedBy == .session)
        #expect(!r.app.settings.profileInSoul)
        #expect(!r.app.settings.profileSkillOnly)
    }

    @Test func noSystemPromptWhenSoulIsWritten() async {
        let r = rig()
        defer { r.cleanup() }
        await r.service.run(choice: nil)
        #expect(r.service.profileAppliedBy == .soul)
        #expect(r.app.settings.profileInSoul)
        #expect(!r.app.settings.profileSkillOnly)
        #expect(r.api.createdSystemPrompts == [nil])
    }

    @Test func skillOnlyWhenTheEngineIgnoresTheSystemPrompt() async {
        let r = rig()
        defer { r.cleanup() }
        r.api.reportsSystemPrompt = false
        r.shell.setFile(Self.soul, "My own soul\n")
        await r.service.run(choice: nil)
        #expect(r.service.profileAppliedBy == .skillOnly)
        #expect(r.app.settings.profileSkillOnly)
    }

    @Test func healthTimeoutStopsWithAPlainSentence() async {
        let r = rig(detailed: 503)
        defer { r.cleanup() }
        await r.service.run(choice: .pasteExisting("k"))
        guard case .failed(let m) = r.service.lines[.privateKey] else { Issue.record("expected failed"); return }
        #expect(m == "Hermes didn't accept that key.")
        // The refused key isn't kept, so the next launch still opens the onboarding.
        #expect(!r.app.key.isSet)
        #expect(r.app.onboardingShouldOpen)
        #expect(r.service.lines[.wrotePersonality] == .pending)
    }

    // MARK: C1, C2

    @Test func unreadableConfigStopsLineThreeAndChangesNothing() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "model: x\n")
        r.shell.makeUnreadable(Self.config)
        await r.service.run(choice: nil)
        #expect(r.service.lines[.privateKey] == .failed(EngineService.unreadableConfigMessage))
        #expect(r.shell.files[Self.config] == "model: x\n")
        #expect(!r.shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) && $0.last?.contains("gateway") == true })
        #expect(r.service.lines[.wrotePersonality] == .pending)
    }

    @Test func aGatewayOutsideKobeAsksThePersonToRestartIt() async {
        let r = rig(detailed: 401)
        defer { r.cleanup() }
        r.shell.script(["launchctl", "print"], status: 113)
        await r.service.run(choice: nil)
        #expect(r.service.lines[.privateKey] == .needsAction(EngineService.foreignGatewayMessage))
        #expect(!r.shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) && $0.last?.contains("gateway") == true })
        #expect(r.shell.files["/fake/home/Library/LaunchAgents/com.kobe-assistant.gateway.plist"] == nil)
        #expect(r.service.lines[.wrotePersonality] == .pending)
    }

    @Test func rotatingNeverTouchesAGatewayOutsideKobe() async {
        let r = rig(detailed: 401)
        defer { r.cleanup() }
        r.shell.setFile(Self.config, Self.keyed)
        r.shell.script(["launchctl", "print"], status: 113)
        await r.service.run(choice: .rotate)
        #expect(r.service.lines[.privateKey] == .needsAction(EngineService.foreignGatewayMessage))
        #expect(r.shell.files[Self.config] == Self.keyed)
        #expect(!r.app.key.isSet)
    }

    // MARK: I1: Hermes runs as another user

    @Test func anotherUsersEngineSkipsTheEngineSide() async {
        let r = rig()
        defer { r.cleanup() }
        r.app.settings.engineSeparateUser = true
        r.app.key.save("pasted-engine-key")
        await r.service.run(choice: nil)
        for line in [ConnectLine.gaveKey, .installedSkill, .privateKey, .wrotePersonality] {
            #expect(r.service.lines[line] == .skipped(ConnectService.skippedElsewhere))
        }
        #expect(r.service.lines[.firstHello] == .done)
        #expect(r.shell.files.keys.allSatisfy { !$0.hasPrefix("/fake/home/.hermes") })
        #expect(r.shell.directories.allSatisfy { !$0.hasPrefix("/fake/home/.hermes") })
        #expect(!r.shell.calls.contains { $0.first == "launchctl" || $0.first == "hermes" || $0.first == "rsync" })
        // The person manages SOUL.md over there: the hello injects no profile either.
        #expect(r.api.createdSystemPrompts == [nil])
        #expect(r.app.key.load() == "pasted-engine-key")
    }
}
