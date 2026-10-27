import Foundation
import Testing
@testable import KobeApp
@testable import KobeKit

@MainActor
struct EngineServiceTests {
    static let home = URL(fileURLWithPath: "/fake/home")
    static let config = "/fake/home/.hermes/config.yaml"
    static let binary = "/fake/home/.local/bin/hermes"
    static let gatewayPlist = "/fake/home/Library/LaunchAgents/com.kobe-assistant.gateway.plist"

    struct Rig {
        let service: EngineService
        let shell: FakeShell
        let key: HermesKey
        let host: String
        let cleanup: () -> Void
    }

    /// `status` answers /health; `detailed` answers /health/detailed.
    func rig(health: Int = 200, detailed: Int = 200) -> Rig {
        let stub = StubHTTP.make { $0.url?.path.hasSuffix("detailed") == true ? detailed : health }
        let sandbox = TestSandbox()
        let settings = TestApp.settings(suiteName: sandbox.suiteName)
        settings.serverURL = stub.base.absoluteString
        let shell = FakeShell()
        let key = HermesKey(store: InMemorySecrets())
        shell.setFile(Self.binary, "")
        let service = EngineService(settings: settings, shell: shell, key: key, session: stub.session, home: Self.home)
        return Rig(service: service, shell: shell, key: key, host: stub.host, cleanup: sandbox.cleanup)
    }

    @Test func demoReportsRunningWithoutTheNetwork() async {
        let stub = StubHTTP.make { _ in 500 }
        let sandbox = TestSandbox()
        defer { sandbox.cleanup() }
        let settings = TestApp.settings(suiteName: sandbox.suiteName)
        settings.serverURL = stub.base.absoluteString
        let shell = FakeShell()
        let service = EngineService(settings: settings, shell: shell, key: HermesKey(store: InMemorySecrets()),
                                    session: stub.session, home: Self.home, demo: true)
        await service.check()
        #expect(service.state == .running(version: "demo"))
        await service.turnOn()
        service.install()
        #expect(StubHTTP.requests(stub.host).isEmpty)
        #expect(shell.calls.isEmpty)
        #expect(service.state == .running(version: "demo"))
    }

    @Test func checkReportsRunning() async {
        let r = rig()
        defer { r.cleanup() }
        r.key.save("k-abc")
        await r.service.check()
        #expect(r.service.state == .running(version: "1.2.3"))
        let reqs = StubHTTP.requests(r.host)
        #expect(reqs.first { $0.url?.path == "/health" }?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(reqs.first { $0.url?.path == "/health/detailed" }?.value(forHTTPHeaderField: "Authorization") == "Bearer k-abc")
    }

    @Test func checkReportsApiOff() async {
        let r = rig(health: 500)
        defer { r.cleanup() }
        r.shell.setFile("/fake/home/.local/bin/hermes", "")
        await r.service.check()
        #expect(r.service.state == .installedApiOff)
    }

    @Test func checkReportsNotInstalled() async {
        let r = rig(health: 500)
        defer { r.cleanup() }
        try? r.shell.remove(Self.binary)
        await r.service.check()
        #expect(r.service.state == .notInstalled)
    }

    @Test func turnOnWritesConfigAndStartsGateway() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "model: x\n")
        await r.service.turnOn()
        #expect(r.service.problem == nil)
        let yaml = r.shell.files[Self.config] ?? ""
        #expect(HermesConfig.apiServer(in: yaml)?.hasKey == true)
        #expect(yaml.contains("model: x"))
        #expect(r.shell.modes[Self.config] == 0o600)
        #expect(r.key.isSet)
        #expect(yaml.contains(r.key.load()!))
        let plist = r.shell.files["/fake/home/Library/LaunchAgents/com.kobe-assistant.gateway.plist"] ?? ""
        #expect(plist.contains("com.kobe-assistant.gateway"))
        #expect(plist.contains("/fake/home/.local/bin/hermes"))
        #expect(r.shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) })
        #expect(!r.service.busy)
        #expect(r.service.state == .running(version: "1.2.3"))
    }

    @Test func neverRotatesSilently() async throws {
        let r = rig()
        defer { r.cleanup() }
        let existing = "gateway:\n  api_server:\n    enabled: true\n    host: 127.0.0.1\n    port: 8642\n    key: old-key\n"
        r.shell.setFile(Self.config, existing)
        r.key.save("kept")
        #expect(r.service.existingApiServer() == .keyed)
        try await r.service.ensureApiServer(rotate: false)
        #expect(r.shell.files[Self.config] == existing)
        #expect(r.key.load() == "kept")
    }

    @Test func rotateWritesANewKey() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "gateway:\n  api_server:\n    key: old-key\n")
        r.key.save("kept")
        try await r.service.ensureApiServer(rotate: true)
        #expect(r.key.load() != "kept")
        #expect(r.shell.files[Self.config]?.contains("old-key") == false)
    }

    @Test func existingApiServerIsNilWithoutFile() {
        let r = rig()
        defer { r.cleanup() }
        #expect(r.service.existingApiServer() == .absent)
    }

    @Test func inlineShapeThrowsPlainSentence() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "gateway: {}\n")
        await r.service.turnOn()
        #expect(r.service.problem == "Hermes's config has a shape Kobe can't edit. Set gateway.api_server yourself: enabled, host, port and a key.")
        #expect(!r.service.busy)
        #expect(r.shell.files[Self.config] == "gateway: {}\n")
    }

    @Test func noSecretInArgv() async {
        let r = rig()
        defer { r.cleanup() }
        await r.service.turnOn()
        let secret = r.key.load()
        #expect(secret != nil)
        #expect(r.shell.argvContains(secret!) == false)
        #expect(r.shell.envs.allSatisfy { !$0.values.contains { $0.contains(secret!) } })
    }

    @Test func waitForHealthTimesOut() async {
        let r = rig(detailed: 503)
        defer { r.cleanup() }
        r.key.save("k")
        #expect(await r.service.waitForHealth(timeout: .milliseconds(700)) == false)
    }

    @Test func installOpensTerminalWithTheInstaller() async {
        let r = rig()
        defer { r.cleanup() }
        r.service.install()
        #expect(await TestApp.eventually { r.shell.calls.contains { $0.starts(with: ["open", "-a", "Terminal"]) } })
        #expect(r.shell.files.values.contains { $0.contains(EngineDetection.installCommand) })
        #expect(r.shell.files.keys.allSatisfy { $0.hasPrefix("/fake/home") })
        #expect(r.shell.directories.allSatisfy { $0.hasPrefix("/fake/home") })
        #expect(await TestApp.eventually { !r.service.busy })
    }

    @Test func installIgnoredWhileBusy() async {
        let r = rig()
        defer { r.cleanup() }
        r.service.install()
        r.service.install()
        #expect(await TestApp.eventually { !r.service.busy })
        #expect(r.shell.calls.filter { $0.starts(with: ["open", "-a", "Terminal"]) }.count == 1)
    }

    @Test func waitForHealthStopsWhenCancelled() async {
        let r = rig(detailed: 503)
        defer { r.cleanup() }
        r.key.save("k")
        let service = r.service
        let task = Task { await service.waitForHealth(timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        #expect(await task.value == false)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func keyedConfigWithoutKeychainKeyAsksForAChoice() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "gateway:\n  api_server:\n    enabled: true\n    key: old-key\n")
        await r.service.turnOn()
        #expect(r.service.needsKeyChoice)
        #expect(r.service.problem == "Kobe doesn't have the engine's key. Rotate it here, or paste it under Advanced.")
        #expect(!r.shell.calls.contains { $0.first == "launchctl" })
        #expect(!r.key.isSet)
    }

    @Test func blockWithoutKeyGetsOne() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "gateway:\n  api_server:\n    enabled: true\n")
        try await r.service.ensureApiServer(rotate: false)
        #expect(HermesConfig.apiServer(in: r.shell.files[Self.config] ?? "")?.hasKey == true)
        #expect(r.key.isSet)
    }

    // MARK: C1: an unreadable config is never overwritten; the first write keeps a backup

    @Test func unreadableConfigThrowsAndChangesNothing() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "model: x\n")
        r.shell.makeUnreadable(Self.config)
        #expect(r.service.existingApiServer() == .unreadable)
        await #expect(throws: EngineService.Failure.self) { try await r.service.ensureApiServer(rotate: false) }
        await #expect(throws: EngineService.Failure.self) { try await r.service.ensureApiServer(rotate: true) }
        #expect(r.shell.files[Self.config] == "model: x\n")
        #expect(!r.key.isSet)
        await r.service.turnOn()
        #expect(r.service.problem == "Kobe couldn't read ~/.hermes/config.yaml, so it changed nothing.")
        #expect(!r.shell.calls.contains { $0.first == "launchctl" })
        #expect(r.shell.files.keys.filter { $0.contains("kobe-backup") }.isEmpty)
    }

    @Test func firstWriteKeepsABackup() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "model: x\n")
        try await r.service.ensureApiServer(rotate: false)
        let backups = r.shell.files.keys.filter { $0.hasPrefix(Self.config + ".kobe-backup-") }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(r.shell.files[backup] == "model: x\n")
        #expect(r.shell.modes[backup] == 0o600)
        #expect(backup.range(of: #"kobe-backup-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
        // A later write (a rotation) keeps the original backup and makes no second one.
        try await r.service.ensureApiServer(rotate: true)
        #expect(r.shell.files.keys.filter { $0.hasPrefix(Self.config + ".kobe-backup-") } == [backup])
        #expect(r.shell.files[backup] == "model: x\n")
    }

    @Test func noBackupWithoutAConfig() async throws {
        let r = rig()
        defer { r.cleanup() }
        try await r.service.ensureApiServer(rotate: false)
        #expect(r.shell.files.keys.filter { $0.contains("kobe-backup") }.isEmpty)
    }

    // Task 10: a keyed block that is off, or on another port, is merged (key kept) instead of left alone.
    @Test func keyedButDisabledBlockIsTurnedOnKeepingTheKey() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "gateway:\n  api_server:\n    enabled: false\n    host: 127.0.0.1\n    port: 8642\n    key: old-key\n")
        r.key.save("old-key")
        try await r.service.ensureApiServer(rotate: false)
        let block = HermesConfig.apiServer(in: r.shell.files[Self.config] ?? "")
        #expect(block?.enabled == true)
        #expect(r.shell.files[Self.config]?.contains("key: old-key") == true)
        #expect(r.key.load() == "old-key")
    }

    @Test func keyedBlockOnAnotherPortGetsTheSettingsPort() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.config, "gateway:\n  api_server:\n    enabled: true\n    host: 127.0.0.1\n    port: 9000\n    key: old-key\n")
        r.key.save("old-key")
        try await r.service.ensureApiServer(rotate: false)
        let block = HermesConfig.apiServer(in: r.shell.files[Self.config] ?? "")
        #expect(block?.port == 8642)
        #expect(r.shell.files[Self.config]?.contains("key: old-key") == true)
        #expect(r.key.load() == "old-key")
    }

    // MARK: C2: Kobe starts only its own gateway

    @Test func gatewayRunningOutsideKobeIsNotStartedTwice() async {
        let r = rig(health: 200, detailed: 401)
        defer { r.cleanup() }
        r.shell.script(["launchctl", "print"], status: 113, stderr: "Could not find service")
        r.key.save("k")
        do {
            try await r.service.startGateway()
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription == EngineService.foreignGatewayMessage)
            #expect(error is EngineService.ForeignGateway)
        }
        #expect(!r.shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) })
        #expect(!r.shell.calls.contains { $0.starts(with: ["launchctl", "bootout"]) })
        #expect(r.shell.files[Self.gatewayPlist] == nil)
        #expect(EngineService.foreignGatewayMessage.contains("hermes gateway"))
    }

    @Test func gatewayOutsideKobeThatAcceptsTheKeyNeedsNoRestart() async throws {
        let r = rig(health: 200, detailed: 200)
        defer { r.cleanup() }
        r.shell.script(["launchctl", "print"], status: 113)
        r.key.save("k")
        try await r.service.startGateway()
        #expect(!r.shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) })
        #expect(r.shell.files[Self.gatewayPlist] == nil)
    }

    @Test func gatewayStartsWhenNothingAnswers() async throws {
        let r = rig(health: 500, detailed: 500)
        defer { r.cleanup() }
        r.shell.script(["launchctl", "print"], status: 113)
        try await r.service.startGateway()
        #expect(r.shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) })
    }

    @Test func kobesOwnGatewayIsRestarted() async throws {
        let r = rig(health: 200, detailed: 401)
        defer { r.cleanup() }
        r.shell.script(["launchctl", "print"], status: 0)
        try await r.service.startGateway()
        let uid = getuid()
        #expect(r.shell.calls.contains(["launchctl", "print", "gui/\(uid)/com.kobe-assistant.gateway"]))
        #expect(r.shell.calls.contains { $0.starts(with: ["launchctl", "bootstrap"]) })
    }

    @Test func missingHermesCommandStopsBeforeThePlist() async {
        let r = rig(health: 500)
        defer { r.cleanup() }
        try? r.shell.remove(Self.binary)
        await #expect(throws: EngineService.Failure.self) { try await r.service.startGateway() }
        do { try await r.service.startGateway() } catch {
            #expect(error.localizedDescription == "Kobe can't find the hermes command at ~/.local/bin/hermes.")
        }
        #expect(r.shell.files[Self.gatewayPlist] == nil)
        #expect(!r.shell.calls.contains { $0.first == "launchctl" })
    }

    @Test func gatewayPlistRestartsOnlyAfterACrash() async throws {
        let r = rig(health: 500)
        defer { r.cleanup() }
        try await r.service.startGateway()
        let text = try #require(r.shell.files[Self.gatewayPlist])
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(plist["ThrottleInterval"] as? Int == 10)
    }
}
