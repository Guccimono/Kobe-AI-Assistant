import Foundation
import Observation
import KobeKit

enum ConnectLine: CaseIterable { case gaveKey, installedSkill, privateKey, wrotePersonality, firstHello }

/// `needsAction`: the person has something to do outside Kobe (restart their own gateway), then "Check again".
/// `skipped`: not Kobe's to do in this setup (Hermes runs as another user).
enum LineState: Equatable { case pending, running, done, skipped(String), needsChoice(String), needsAction(String), failed(String) }

/// What the person decided when Hermes already had a key for its API.
enum EngineKeyChoice { case pasteExisting(String), rotate }

/// How the assistant's personality reached the engine.
enum ProfileApplied: Equatable { case soul, session, skillOnly }

/// The onboarding's "Connecting" screen, behind the glass: five lines, each through the other services and the
/// `ShellRunner`. Runs only when called: no timers.
@MainActor @Observable
final class ConnectService {
    static let skillMissing = "The Kobe skill isn't in this build"
    static let personalityOnTop = "Your assistant already has a personality in Hermes; Kobe adds its name and tone on top."
    static let skippedElsewhere = "Skipped — Hermes runs as another user"
    static let helloPrompt = "Say hello in one short sentence and ask whether to start with my calendar or my inbox."

    private(set) var lines: [ConnectLine: LineState] = Dictionary(uniqueKeysWithValues: ConnectLine.allCases.map { ($0, .pending) })
    private(set) var hello: String?
    private(set) var busy = false
    /// nil until known: `.soul` once SOUL.md is written, else decided by the first hello's session.
    private(set) var profileAppliedBy: ProfileApplied?
    /// The gateway is being (re)started: the private-key line says so.
    private(set) var restarting = false
    static let restartingNote = "Restarting the engine… your Telegram/WhatsApp bridges reconnect by themselves"

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let engine: EngineService
    @ObservationIgnored private let brain: BrainService
    @ObservationIgnored private let shell: any ShellRunner
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let agentSource: URL?

    init(app: AppModel, engine: EngineService, brain: BrainService, shell: any ShellRunner, home: URL, agentSource: URL?) {
        self.app = app
        self.engine = engine
        self.brain = brain
        self.shell = shell
        self.home = home
        self.agentSource = agentSource
    }

    private var hermesDir: String { home.appendingPathComponent(".hermes").path }
    private var soulPath: String { hermesDir + "/SOUL.md" }
    private var profile: Profile {
        Profile(name: app.settings.assistantName, role: app.settings.assistantRole, tone: app.settings.assistantTone)
    }

    // MARK: Run

    func run(choice: EngineKeyChoice?) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        for line in ConnectLine.allCases { lines[line] = .pending }
        profileAppliedBy = nil
        hello = nil

        // Hermes runs as another macOS user: its brain, skill, key and personality are set over there, and nothing
        // is written under this user's ~/.hermes. The pasted engine key carries the first hello, with no profile:
        // the person manages SOUL.md over there.
        if app.settings.engineSeparateUser {
            for line in [ConnectLine.gaveKey, .installedSkill, .privateKey, .wrotePersonality] {
                lines[line] = .skipped(Self.skippedElsewhere)
            }
            app.settings.profileInSoul = false
            await firstHello()
            return
        }

        // 1. Give the engine the brain's key. Nothing works without it: stop on failure.
        lines[.gaveKey] = .running
        if !app.brainKeptFromHermes {
            do { try await brain.handOver(brain: app.settings.selectedBrain) }
            catch { lines[.gaveKey] = .failed(error.localizedDescription); return }
            // The key is in .env, but the model wasn't set: the engine would answer with the wrong one, or not at all.
            if let problem = brain.problem { lines[.gaveKey] = .failed(problem); return }
        }
        lines[.gaveKey] = .done

        // 2. The skill. A build without it goes on.
        lines[.installedSkill] = .running
        do { try await installSkill(); lines[.installedSkill] = .done }
        catch { lines[.installedSkill] = .failed(error.localizedDescription) }

        // 3. The private Kobe-to-engine key.
        lines[.privateKey] = .running
        switch await connectPrivateKey(choice: choice) {
        case .done: lines[.privateKey] = .done
        case let other: lines[.privateKey] = other; return
        }

        // 4. The personality.
        lines[.wrotePersonality] = .running
        do { try writePersonality(); lines[.wrotePersonality] = .done }
        catch { lines[.wrotePersonality] = .failed(error.localizedDescription) }

        // 5. The first hello.
        await firstHello()
    }

    private func connectPrivateKey(choice: EngineKeyChoice?) async -> LineState {
        switch engine.existingApiServer() {
        case .unreadable:
            return .failed(EngineService.unreadableConfigMessage)
        case .keyed where app.key.load() == nil && choice == nil:
            return .needsChoice("Hermes already has a key for its API. Paste it, or let Kobe create a new one — other apps using the old key will need the new one.")
        default: break
        }
        var timeout = Duration.seconds(20)
        do {
            switch choice {
            case .pasteExisting(let pasted):
                // Nothing restarts: the key is only kept, then tried once.
                guard app.key.save(pasted) else { return .failed("Kobe couldn't keep that key.") }
                timeout = .seconds(5)
            case .rotate:
                // A gateway Kobe didn't start keeps its key: rotating would only lock it out.
                if await engine.gatewayOwner() == .someoneElse { return .needsAction(EngineService.foreignGatewayMessage) }
                try await engine.ensureApiServer(rotate: true)
                try await restartGateway()
            case nil:
                try await engine.ensureApiServer(rotate: false)
                try await restartGateway()
            }
        } catch let foreign as EngineService.ForeignGateway {
            return .needsAction(foreign.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard await engine.waitForHealth(timeout: timeout) else {
            if case .pasteExisting = choice {
                // A key the engine refused isn't kept: the next launch would think Kobe is set up.
                app.key.delete()
                return .failed("Hermes didn't accept that key.")
            }
            return .failed("Hermes didn't answer in time.")
        }
        return .done
    }

    private func restartGateway() async throws {
        restarting = true
        defer { restarting = false }
        try await engine.startGateway()
    }

    // MARK: Pieces

    func installSkill() async throws {
        guard let source = agentSource, shell.fileExists(source.path) else {
            throw AgentInstaller.Failure(message: Self.skillMissing)
        }
        try await AgentInstaller.install(from: source, home: home, exchangeFolder: app.settings.exchangeFolder,
                                         shared: app.settings.engineSeparateUser,
                                         serviceKeys: app.keys, shell: shell)
    }

    /// `profile.md` always; `SOUL.md` only when it is absent or still Kobe's own. A file that exists but can't be
    /// read is left alone.
    func writePersonality() throws {
        let p = profile
        try shell.mkdir(hermesDir + "/kobe")
        try shell.write(hermesDir + "/kobe/profile.md", ProfileFiles.profileMarkdown(p), mode: 0o644)
        let unreadable = shell.fileExists(soulPath) && shell.read(soulPath) == nil
        if !unreadable, ProfileFiles.mayWriteSoul(existing: shell.read(soulPath)) {
            try shell.write(soulPath, ProfileFiles.soul(p), mode: 0o644)
            profileAppliedBy = .soul
        } else {
            profileAppliedBy = nil
        }
        // Every later chat carries the profile itself unless SOUL.md is Kobe's.
        app.settings.profileInSoul = profileAppliedBy == .soul
        if profileAppliedBy == .soul { app.settings.profileSkillOnly = false }
    }

    /// A session titled "Kobe", one turn, and the first line of the reply. If SOUL.md carries the personality the
    /// session needs no system prompt; otherwise it gets one, and the engine says whether it kept it.
    func firstHello() async {
        lines[.firstHello] = .running
        let p = profile
        let fallback = ProfileFiles.hello(p)
        // Another user's Hermes keeps its own SOUL.md: no profile is injected there.
        let wantsPrompt = profileAppliedBy != .soul && !app.settings.engineSeparateUser
        do {
            let session = try await app.api.createSession(title: "Kobe", systemPrompt: wantsPrompt ? ProfileFiles.systemPrompt(p) : nil)
            if wantsPrompt {
                let kept = (try? await app.api.listSessions(limit: 20))?.first { $0.id == session.id }?.hasSystemPrompt
                profileAppliedBy = (kept ?? session.hasSystemPrompt) == true ? .session : .skillOnly
                app.settings.profileSkillOnly = profileAppliedBy == .skillOnly
            }
            var reply: String?
            var failure: String?
            for try await event in try await app.api.stream(sessionID: session.id, message: Self.helloPrompt) {
                switch event {
                case .completed(let content, _): reply = content
                case .failed(let message): failure = message
                default: break
                }
            }
            if let line = reply?.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
                hello = line
                lines[.firstHello] = .done
            } else {
                hello = fallback
                lines[.firstHello] = .failed(failure ?? "\(Copy(name: p.name).name) didn't answer.")
            }
        } catch {
            hello = fallback
            lines[.firstHello] = .failed("\(Copy(name: p.name).name) didn't answer.")
        }
    }
}
