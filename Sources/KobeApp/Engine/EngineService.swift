import Foundation
import Observation
import KobeKit

/// The onboarding's engine screen, behind the glass: finds Hermes, offers its installer in Terminal, turns its
/// API server on and waits for it to answer. Everything outside goes through `ShellRunner` and a `URLSession`.
/// Runs only when called: no timers.
@MainActor @Observable
final class EngineService {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let configShapeMessage = "Hermes's config has a shape Kobe can't edit. Set gateway.api_server yourself: enabled, host, port and a key."
    static let launchAgentLabel = "com.kobe-assistant.gateway"

    private(set) var state: EngineState?
    private(set) var busy = false
    private(set) var problem: String?
    /// The config already has a key but the Keychain doesn't: the UI offers "rotate" or "paste the key".
    private(set) var needsKeyChoice = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let shell: any ShellRunner
    @ObservationIgnored private let key: HermesKey
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let home: URL
    /// `--demo`: the engine always answers "running", with no network and nothing installed or started.
    @ObservationIgnored private let demo: Bool

    init(settings: AppSettings, shell: any ShellRunner, key: HermesKey, session: URLSession = .kobeLoopback,
         home: URL = FileManager.default.homeDirectoryForCurrentUser, demo: Bool = false) {
        self.demo = demo
        self.settings = settings
        self.shell = shell
        self.key = key
        self.session = session
        self.home = home
    }

    // MARK: Where things are

    /// Read at call time, so a port typed in Advanced is honoured.
    var baseURL: URL { URL(string: settings.serverURL) ?? URL(string: AppSettings.defaultServerURL)! }
    var port: Int { baseURL.port ?? 8642 }

    private var hermesDir: String { home.appendingPathComponent(".hermes").path }
    private var configPath: String { hermesDir + "/config.yaml" }
    private var binaryPath: String { home.appendingPathComponent(".local/bin/hermes").path }
    private var agentPlist: String { home.appendingPathComponent("Library/LaunchAgents/\(Self.launchAgentLabel).plist").path }
    private var logFolder: String { hermesDir + "/kobe/logs" }

    // MARK: Detect

    func check() async {
        if demo { state = .running(version: "demo"); return }
        let base = baseURL
        let reachable = await get(EngineDetection.healthURL(base: base), bearer: nil)?.ok ?? false
        var version: String?
        if reachable, let k = key.load(),
           let detailed = await get(EngineDetection.detailedURL(base: base), bearer: k), detailed.ok {
            version = (try? JSONSerialization.jsonObject(with: detailed.body) as? [String: Any])?["version"] as? String
        }
        let probe = EngineProbe(healthReachable: reachable, version: version,
                                hermesHome: shell.fileExists(hermesDir + "/hermes-agent"),
                                hermesBinary: shell.fileExists(binaryPath))
        state = EngineDetection.state(probe)
    }

    private func get(_ url: URL, bearer: String?) async -> (ok: Bool, body: Data)? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return ((200..<300).contains(http.statusCode), data)
    }

    // MARK: Install

    func install() {
        guard !demo, !busy else { return }
        problem = nil
        busy = true
        let shell = shell
        let folder = home.appendingPathComponent("Library/Application Support/\(Brand.dataFolderName)/terminal").path
        Task { [weak self] in
            do { try await TerminalLauncher.run(EngineDetection.installCommand, shell: shell, folder: folder) }
            catch { self?.problem = error.localizedDescription }
            self?.busy = false
        }
    }

    // MARK: Turn on

    nonisolated static let elsewhereMessage = "Off while Hermes runs as another user: turn it on and change its key there."
    nonisolated static let unreadableConfigMessage = "Kobe couldn't read ~/.hermes/config.yaml, so it changed nothing."
    nonisolated static let missingBinaryMessage = "Kobe can't find the hermes command at ~/.local/bin/hermes."
    nonisolated static let foreignGatewayMessage = "Hermes is already running outside Kobe. Restart it yourself so it picks up the new settings, then press Check again. If you started it in Terminal, stop it there and run: hermes gateway"

    /// What `config.yaml` says about the API server, as far as Kobe can read it.
    enum ApiServerPresence: Equatable { case absent, keyed, unkeyed, unreadable }

    /// Who runs the gateway now: Kobe's own LaunchAgent, nobody, or the person (their service or a Terminal).
    enum GatewayOwner: Equatable { case kobe, nobody, someoneElse }

    /// A gateway Kobe didn't start answers: Kobe never starts a second one.
    struct ForeignGateway: Error, LocalizedError {
        var errorDescription: String? { EngineService.foreignGatewayMessage }
    }

    /// `.unreadable` when the file exists but can't be read (permissions, a byte that isn't UTF-8).
    func existingApiServer() -> ApiServerPresence {
        guard shell.fileExists(configPath) else { return .absent }
        guard let yaml = shell.read(configPath) else { return .unreadable }
        guard let block = HermesConfig.apiServer(in: yaml) else { return .absent }
        return block.hasKey ? .keyed : .unkeyed
    }

    /// Writes the api_server block with a fresh private key when there is none (or when asked to rotate), and keeps
    /// the key in the Keychain. An existing key is never replaced silently; a keyed block that is off or on another
    /// port is turned on with its key kept. A config that can't be read is never touched, and the first write keeps
    /// a copy of the file beside it.
    func ensureApiServer(rotate: Bool) async throws {
        if shell.fileExists(configPath), shell.read(configPath) == nil {
            throw Failure(message: Self.unreadableConfigMessage)
        }
        let existing = shell.read(configPath)
        let host = "127.0.0.1"
        var newKey: String? = HermesConfig.newEngineKey()
        if !rotate, let existing, let block = HermesConfig.apiServer(in: existing), block.hasKey {
            if block.enabled, block.port == port { return }
            newKey = nil   // keep the block's own key
        }
        guard let merged = HermesConfig.mergeApiServer(into: existing ?? "", host: host, port: port, key: newKey) else {
            throw Failure(message: Self.configShapeMessage)
        }
        try shell.mkdir(hermesDir)
        if let existing { try backUpConfigOnce(existing) }
        try shell.write(configPath, merged, mode: 0o600)
        if let newKey, !key.save(newKey) { throw Failure(message: "Kobe couldn't save the engine key in the Keychain.") }
    }

    /// `config.yaml.kobe-backup-<yyyyMMdd-HHmmss>`, 0600, made before Kobe's first change to the file and never again.
    private func backUpConfigOnce(_ text: String) throws {
        let prefix = "config.yaml.kobe-backup-"
        guard !shell.list(hermesDir).contains(where: { $0.hasPrefix(prefix) }) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        try shell.write(hermesDir + "/" + prefix + formatter.string(from: Date()), text, mode: 0o600)
    }

    private var launchDomain: String { "gui/\(getuid())" }

    /// Kobe's LaunchAgent is loaded → Kobe's. Else a `/health` answer means someone else's gateway.
    func gatewayOwner() async -> GatewayOwner {
        let loaded = await shell.run(["launchctl", "print", "\(launchDomain)/\(Self.launchAgentLabel)"], stdin: nil, env: [:])
        if loaded.status == 0 { return .kobe }
        let up = await get(EngineDetection.healthURL(base: baseURL), bearer: nil)?.ok ?? false
        return up ? .someoneElse : .nobody
    }

    /// Starts (or restarts) the gateway through Kobe's LaunchAgent, only when that agent is Kobe's or no gateway
    /// answers. A gateway the person runs is never doubled: if it already takes Kobe's key nothing happens, else
    /// `ForeignGateway` asks them to restart it themselves.
    func startGateway() async throws {
        guard shell.fileExists(binaryPath) else { throw Failure(message: Self.missingBinaryMessage) }
        if await gatewayOwner() == .someoneElse {
            if let k = key.load(), await get(EngineDetection.detailedURL(base: baseURL), bearer: k)?.ok == true { return }
            throw ForeignGateway()
        }
        try shell.mkdir(logFolder)
        try shell.mkdir((agentPlist as NSString).deletingLastPathComponent)
        let log = logFolder + "/gateway.log"
        let plist: [String: Any] = [
            "Label": Self.launchAgentLabel,
            "ProgramArguments": [binaryPath, "gateway"],
            "RunAtLoad": true,
            // Restarted after a crash, not after a clean exit; at most every 10 s.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try shell.write(agentPlist, String(decoding: data, as: UTF8.self), mode: 0o644)
        let domain = launchDomain
        _ = await shell.run(["launchctl", "bootout", "\(domain)/\(Self.launchAgentLabel)"], stdin: nil, env: [:])
        let r = await shell.run(["launchctl", "bootstrap", domain, agentPlist], stdin: nil, env: [:])
        if r.status != 0 {
            let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "Kobe couldn't start Hermes." : "Kobe couldn't start Hermes: \(detail)")
        }
    }

    func turnOn() async {
        guard !demo else { return }
        // Another user's Hermes: its config and its gateway are not Kobe's to touch.
        if settings.engineSeparateUser { problem = Self.elsewhereMessage; return }
        busy = true
        problem = nil
        needsKeyChoice = false
        defer { busy = false }
        switch existingApiServer() {
        case .unreadable:
            problem = Self.unreadableConfigMessage
            await check()
            return
        case .keyed where key.load() == nil:
            needsKeyChoice = true
            await check()
            problem = "Kobe doesn't have the engine's key. Rotate it here, or paste it under Advanced."
            return
        default: break
        }
        do {
            try await ensureApiServer(rotate: false)
            try await startGateway()
            guard await waitForHealth(timeout: .seconds(20)) else {
                problem = "Hermes didn't answer in time. Try again in a moment."
                await check()
                return
            }
        } catch {
            problem = error.localizedDescription
            return
        }
        await check()
    }

    /// Polls `/health/detailed` with the key every 500 ms until it answers 2xx or the time runs out.
    func waitForHealth(timeout: Duration) async -> Bool {
        if demo { return true }
        let clock = ContinuousClock()
        let end = clock.now + timeout
        let url = EngineDetection.detailedURL(base: baseURL)
        while !Task.isCancelled {
            if await get(url, bearer: key.load())?.ok == true { return true }
            if clock.now >= end { return false }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
        }
        return false
    }
}
