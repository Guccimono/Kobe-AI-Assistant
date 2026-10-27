import AppKit
import Foundation
import Observation
import KobeKit

/// The onboarding's "Pick a brain" screen, behind the glass: reads what Hermes already has, checks a pasted key
/// with one request to the provider, keeps it in the Keychain and hands it to Hermes. The key goes into
/// `~/.hermes/.env` (0600), never into a process argument. Runs only when called: no timers.
@MainActor @Observable
final class BrainService {
    /// Internal set: the onboarding's navigation tests plant a verdict instead of calling the provider.
    var verdict: KeyVerdict?
    private(set) var ollamaRunning: Bool?
    private(set) var hermesAlreadyHas: Brain?
    private(set) var busy = false
    private(set) var problem: String?

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let shell: any ShellRunner
    @ObservationIgnored private let keys: BrainKeys
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let open: (URL) -> Void
    @ObservationIgnored private let checkURL: (Brain) -> URL

    init(settings: AppSettings, shell: any ShellRunner, secrets: any SecretStoring, session: URLSession = .shared,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         checkURL: @escaping (Brain) -> URL = { $0.checkURL }) {
        self.settings = settings
        self.shell = shell
        self.keys = BrainKeys(store: secrets)
        self.session = session
        self.home = home
        self.open = open
        self.checkURL = checkURL
    }

    private var hermesDir: String { home.appendingPathComponent(".hermes").path }
    private var envPath: String { hermesDir + "/.env" }

    // MARK: Read

    func readHermes() {
        hermesAlreadyHas = shell.read(envPath).flatMap { HermesConfig.hasProviderKey(env: $0) }
    }

    // MARK: Check

    /// One GET to the provider's models list. Stores nothing.
    func check(brain: Brain, pasted: String) async {
        let key = KeyCheck.trimmed(pasted)
        var request = URLRequest(url: checkURL(brain), timeoutInterval: 8)
        if brain.needsKey {
            for (name, value) in brain.authHeaders(key: key) { request.setValue(value, forHTTPHeaderField: name) }
        }
        var status: Int?
        var count = 0
        if let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse {
            status = http.statusCode
            let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[brain == .ollama ? "models" : "data"]
            count = (list as? [Any])?.count ?? 0
        }
        if brain == .ollama {
            let up = status.map { (200..<300).contains($0) } ?? false
            ollamaRunning = up
            verdict = up ? .works(models: count) : .unreachable
        } else {
            verdict = KeyCheck.verdict(brain: brain, key: key, status: status, modelCount: count)
        }
    }

    // MARK: Keep

    @discardableResult
    func store(brain: Brain, key: String) -> Bool { keys.save(key, for: brain) }
    func storedKey(for brain: Brain) -> String? { keys.load(brain) }

    // MARK: Hand over

    /// Writes the key (or the Ollama pair) into `~/.hermes/.env`, then sets provider and model through
    /// `hermes config set`. Only non-secret values ever reach argv.
    func handOver(brain: Brain) async throws {
        busy = true
        problem = nil
        defer { busy = false }
        let secret = keys.load(brain)
        var env = ""
        if shell.fileExists(envPath) {
            guard let current = shell.read(envPath) else {
                throw Failure(message: "Kobe couldn't read ~/.hermes/.env, so it changed nothing.")
            }
            env = current
        }
        if brain == .ollama {
            // A real OpenAI key in .env would be overwritten by the Ollama pair: keep it for later.
            if let real = HermesConfig.envValue(env, key: "OPENAI_API_KEY"), !real.isEmpty, real != "ollama",
               keys.load(.openai) == nil {
                keys.save(real, for: .openai)
            }
        } else if let base = HermesConfig.envValue(env, key: "OPENAI_BASE_URL"), base.contains("127.0.0.1:11434") {
            env = HermesConfig.removeEnv(env, key: "OPENAI_BASE_URL")
        }
        for (name, value) in brain.envWrites {
            guard let v = value ?? secret else {
                throw Failure(message: "Kobe doesn't have a key for \(brain.label) yet.")
            }
            env = HermesConfig.setEnv(env, key: name, value: v)
        }
        try shell.mkdir(hermesDir)
        try shell.write(envPath, env, mode: 0o600)

        let (commands, skipped) = Self.safeConfigCommands(brain.modelConfig)
        // One key per command, in order; the first refusal stops the rest, so a half-set model isn't built on.
        var refusal: String?
        for argv in commands {
            let r = await shell.run(argv, stdin: nil, env: [:])
            if r.status != 0 {
                let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                refusal = "Kobe set the key, but `hermes config set` refused the model: " + (detail.isEmpty ? "no reason given." : detail)
                break
            }
        }
        if let refusal {
            problem = refusal
        } else if !skipped.isEmpty {
            problem = "Kobe set the key, but left \(skipped.joined(separator: ", ")) alone because it looks like a key."
        }
    }

    /// `hermes config set` commands for the pairs whose value doesn't look like a key (`sk-`). Skipped names come back.
    nonisolated static func safeConfigCommands(_ pairs: [(key: String, value: String)]) -> (run: [[String]], skipped: [String]) {
        let safe = pairs.filter { !$0.value.hasPrefix("sk-") }
        return (HermesConfig.configSetCommands(safe), pairs.filter { $0.value.hasPrefix("sk-") }.map(\.key))
    }

    // MARK: Ollama

    func installOllama() {
        if let url = Brain.ollama.createKeyURL { open(url) }
    }

    /// Opens Terminal with the download so the person can watch it. Returns the command, which the UI shows.
    @discardableResult
    func pullOllamaModel() -> String {
        let command = "ollama pull \(Brain.ollamaModel)"
        let shell = shell
        let folder = home.appendingPathComponent("Library/Application Support/\(Brand.dataFolderName)/terminal").path
        Task { [weak self] in
            do { try await TerminalLauncher.run(command, shell: shell, folder: folder) }
            catch { self?.problem = error.localizedDescription }
        }
        return command
    }
}
