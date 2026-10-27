import Foundation
import Testing
@testable import KobeApp
@testable import KobeKit

@MainActor
struct BrainServiceTests {
    static let home = URL(fileURLWithPath: "/fake/home")
    static let env = "/fake/home/.hermes/.env"

    struct Rig {
        let service: BrainService
        let shell: FakeShell
        let secrets: InMemorySecrets
        let host: String
        let opened: Opened
        let cleanup: () -> Void
    }

    final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.withLock { _urls } }
        func add(_ u: URL) { lock.withLock { _urls.append(u) } }
    }

    /// `status` answers the check; `body` is the JSON it returns.
    func rig(status: Int = 200, body: String = "{}") -> Rig {
        let stub = StubHTTP.make(body: { _ in Data(body.utf8) }) { _ in status }
        let sandbox = TestSandbox()
        let settings = TestApp.settings(suiteName: sandbox.suiteName)
        let shell = FakeShell()
        let secrets = InMemorySecrets()
        let opened = Opened()
        let host = stub.host
        let service = BrainService(settings: settings, shell: shell, secrets: secrets, session: stub.session, home: Self.home,
                                   open: { opened.add($0) },
                                   checkURL: { _ in URL(string: "http://\(host)/v1/models")! })
        return Rig(service: service, shell: shell, secrets: secrets, host: host, opened: opened, cleanup: sandbox.cleanup)
    }

    static func models(_ n: Int) -> String {
        #"{"data":["# + (0..<n).map { #"{"id":"m\#($0)"}"# }.joined(separator: ",") + "]}"
    }

    @Test func checkWorks() async {
        let r = rig(body: Self.models(12))
        defer { r.cleanup() }
        await r.service.check(brain: .claude, pasted: "  sk-ant-abc\n")
        #expect(r.service.verdict == .works(models: 12))
        let req = StubHTTP.requests(r.host).first
        #expect(req?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-abc")
        #expect(req?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(r.secrets.read(service: Brand.servicesKeychain, account: "brain-claude") == nil)
    }

    @Test func checkWrongProvider() async {
        let r = rig(status: 401)
        defer { r.cleanup() }
        await r.service.check(brain: .claude, pasted: "sk-or-abc")
        #expect(r.service.verdict == .wrongProvider(looksLike: .openrouter))
    }

    @Test func checkNoAnswerIsUnreachable() async {
        let r = rig(status: 503)
        defer { r.cleanup() }
        await r.service.check(brain: .openai, pasted: "sk-abc")
        #expect(r.service.verdict == .unreachable)
    }

    @Test func ollamaCheckCountsModels() async {
        let r = rig(body: #"{"models":[{"name":"a"},{"name":"b"}]}"#)
        defer { r.cleanup() }
        await r.service.check(brain: .ollama, pasted: "")
        #expect(r.service.verdict == .works(models: 2))
        #expect(r.service.ollamaRunning == true)
        #expect(StubHTTP.requests(r.host).first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func ollamaDownIsUnreachable() async {
        let r = rig(status: 500)
        defer { r.cleanup() }
        await r.service.check(brain: .ollama, pasted: "")
        #expect(r.service.verdict == .unreachable)
        #expect(r.service.ollamaRunning == false)
    }

    @Test func handOverWritesEnvWithoutArgv() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.env, "FOO=bar\n")
        r.service.store(brain: .claude, key: "sk-ant-secret")
        try await r.service.handOver(brain: .claude)
        let env = r.shell.files[Self.env] ?? ""
        #expect(env.contains("ANTHROPIC_API_KEY=sk-ant-secret"))
        #expect(env.contains("FOO=bar"))
        #expect(r.shell.modes[Self.env] == 0o600)
        #expect(r.shell.directories.contains("/fake/home/.hermes"))
        #expect(r.shell.argvContains("sk-ant-secret") == false)
        #expect(r.shell.argvContains("sk-") == false)
        #expect(r.shell.stdins.allSatisfy { ($0.map { String(decoding: $0, as: UTF8.self) } ?? "").contains("sk-ant-secret") == false })
        #expect(r.shell.envs.allSatisfy { $0.values.allSatisfy { !$0.contains("sk-ant-secret") } })
        #expect(r.shell.calls.contains(["hermes", "config", "set", "provider", "anthropic"]))
        #expect(r.service.problem == nil)
    }

    @Test func handOverKeepsStderrOfRefusedModel() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.script(["hermes", "config", "set"], status: 1, stderr: "unknown model\n")
        r.service.store(brain: .openai, key: "sk-abc")
        try await r.service.handOver(brain: .openai)
        #expect(r.service.problem == "Kobe set the key, but `hermes config set` refused the model: unknown model")
    }

    @Test func handOverStopsAtTheFirstRefusedPair() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.script(["hermes", "config", "set", "provider"], status: 1, stderr: "no such provider")
        r.service.store(brain: .claude, key: "sk-ant-abc")
        try await r.service.handOver(brain: .claude)
        let sets = r.shell.calls.filter { $0.starts(with: ["hermes", "config", "set"]) }
        #expect(sets == [["hermes", "config", "set", "provider", "anthropic"]])
        #expect(r.service.problem == "Kobe set the key, but `hermes config set` refused the model: no such provider")
    }

    @Test func handOverSetsEachPairOnItsOwn() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.service.store(brain: .claude, key: "sk-ant-abc")
        try await r.service.handOver(brain: .claude)
        let sets = r.shell.calls.filter { $0.starts(with: ["hermes", "config", "set"]) }
        #expect(sets == Brain.claude.modelConfig.map { ["hermes", "config", "set", $0.key, $0.value] })
    }

    @Test func handOverOllamaNeedsNoKey() async throws {
        let r = rig()
        defer { r.cleanup() }
        try await r.service.handOver(brain: .ollama)
        let env = r.shell.files[Self.env] ?? ""
        #expect(env.contains("OPENAI_BASE_URL=http://127.0.0.1:11434/v1"))
        #expect(env.contains("OPENAI_API_KEY=ollama"))
    }

    @Test func ollamaThenOpenAIRestoresTheKey() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.env, "OPENAI_API_KEY=sk-real\nFOO=bar\n")
        try await r.service.handOver(brain: .ollama)
        #expect(r.shell.files[Self.env]?.contains("OPENAI_BASE_URL=http://127.0.0.1:11434/v1") == true)
        #expect(r.service.storedKey(for: .openai) == "sk-real")
        try await r.service.handOver(brain: .openai)
        let env = r.shell.files[Self.env] ?? ""
        #expect(!env.contains("OPENAI_BASE_URL"))
        #expect(env.contains("OPENAI_API_KEY=sk-real"))
        #expect(env.contains("FOO=bar"))
    }

    @Test func ollamaKeepsAnAlreadyStoredOpenAIKey() async throws {
        let r = rig()
        defer { r.cleanup() }
        r.service.store(brain: .openai, key: "sk-stored")
        r.shell.setFile(Self.env, "OPENAI_API_KEY=sk-other\n")
        try await r.service.handOver(brain: .ollama)
        #expect(r.service.storedKey(for: .openai) == "sk-stored")
    }

    @Test func unreadableEnvChangesNothing() async {
        let r = rig()
        defer { r.cleanup() }
        r.shell.setFile(Self.env, "FOO=bar\n")
        r.shell.makeUnreadable(Self.env)
        r.service.store(brain: .claude, key: "sk-ant-x")
        await #expect(throws: BrainService.Failure.self) { try await r.service.handOver(brain: .claude) }
        #expect(r.shell.files[Self.env] == "FOO=bar\n")
        #expect(r.shell.calls.isEmpty)
    }

    @Test func handOverSkipsSecretLookingConfigValues() {
        let cmds = BrainService.safeConfigCommands([("provider", "x"), ("model", "sk-leak")])
        #expect(cmds.run == [["hermes", "config", "set", "provider", "x"]])
        #expect(cmds.skipped == ["model"])
    }

    @Test func keepsHermesBrain() {
        let r = rig()
        defer { r.cleanup() }
        r.service.readHermes()
        #expect(r.service.hermesAlreadyHas == nil)
        r.shell.setFile(Self.env, "OPENROUTER_API_KEY=x\n")
        r.service.readHermes()
        #expect(r.service.hermesAlreadyHas == .openrouter)
    }

    @Test func installOllamaOpensTheDownloadPage() {
        let r = rig()
        defer { r.cleanup() }
        r.service.installOllama()
        #expect(r.opened.urls == [URL(string: "https://ollama.com/download")!])
    }

    @Test func pullOllamaModelReturnsTheCommand() async throws {
        let r = rig()
        defer { r.cleanup() }
        let cmd = r.service.pullOllamaModel()
        #expect(cmd == "ollama pull \(Brain.ollamaModel)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(r.shell.calls.contains { $0.first == "open" })
    }
}
