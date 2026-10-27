import AppKit
import SwiftUI
import Carbon.HIToolbox
import Observation
import KobeKit

/// What the notification band shows.
struct Banner: Equatable {
    var icon: PhosphorIcon
    var tint: Color
    var title: String
    var detail: String
    /// Something waits for an answer: the band stays until it's answered.
    var waiting: Bool
}

/// A Claude Code event shown as a card in the island, with the way to answer it when the hook waits.
struct ClaudeCard: Identifiable {
    let id = UUID()
    let event: ClaudeEvent
    let reply: ClaudeSocketServer.Reply?
    /// When it went on screen (a queued card waits its turn first).
    var shownAt = Date()

    /// Which Claude Code session it belongs to, as far as the hook tells: ClaudeEvent carries no session id, so
    /// cards are told apart by project and kind.
    var project: String {
        switch event {
        case .sessionStarted(let p), .step(let p, _), .finished(let p, _), .ended(let p): p
        case .permission(let permission): permission.project
        case .question(let question): question.project
        }
    }
}

/// Which waiting request ⌥⌘Y / ⌥⌘N would answer: the one whose card is on screen.
enum HotKeyTarget: Equatable { case approval, claude }

/// Everything the app shares: settings, the connection to Kobe (Hermes), chats, keep awake, drops and Claude Code.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let key: HermesKey
    let client: HermesClient
    /// The API the chats and onboarding talk to (the client, or a fake in tests).
    let api: any HermesAPI
    let connection: Connection
    let chats: ChatStore
    let keepAwake = KeepAwake()
    let voice = VoiceService()
    let island: IslandModel
    @ObservationIgnored var controller: IslandController?
    @ObservationIgnored var menuBar: MenuBarController?

    /// Keys for Stripe, GitHub and Vercel (their own Keychain service).
    let keys: ServiceKeys
    @ObservationIgnored private let events = ServiceEventSink()
    let stripe: StripeService
    let github: GitHubService
    let vercel: VercelService
    let whatsapp: WhatsAppController
    /// Mail, Calendar, Reminders and Notes, read by the app itself.
    let mac: MacConnectors
    /// The pages' data: the snapshot files in the exchange folder (written by the shim today, by Kobe Agent later).
    let snapshots: SnapshotStore
    /// Where the pages' buttons go (the shim today, request files for Kobe Agent later).
    @ObservationIgnored private(set) var actions: (any ActionSink)!
    /// Refreshes of the connectors Kobe Agent runs (`Handover.owner`) go here instead of the shim.
    @ObservationIgnored private(set) var agentActions: RequestFileActionSink!
    /// Reversible actions waiting out their 5 s undo.
    @ObservationIgnored private(set) var actionQueue: ActionQueue!
    /// The onboarding's three services: the engine, the brain and the first connection.
    let engine: EngineService
    let brain: BrainService
    @ObservationIgnored private(set) var connect: ConnectService!
    /// The seams the engine services use, kept for the agent's secrets.
    @ObservationIgnored private let shell: any ShellRunner
    @ObservationIgnored private let home: URL
    /// The pages' ↻ while it spins.
    let refreshes = RefreshTracker()
    /// The page on screen owns ↑↓, Return, ⌘R, ⌘F (and Esc when it says so).
    let pageKeys = PageKeyboard()
    /// The conversation open on the WhatsApp page (nil: the list). Here so Now's Reply can open one directly.
    var whatsappChat: String?

    /// Badges on the strip and the Home pills, cleared when that page opens.
    var serviceBadges: [WidgetID: ServiceEvent.Kind] = [:]
    /// Puts the caret in the next composer on screen (Home's, after a drop); the composer clears it.
    var composerFocusPending = false
    /// The latest background event, shown in the band for a few seconds.
    var serviceNotice: ServiceEvent?
    @ObservationIgnored private var noticeClear: Task<Void, Never>?

    var connectionServices: [String: any ConnectionService] {
        ["stripe": stripe, "github": github, "vercel": vercel, "whatsapp": whatsapp]
    }

    /// The four pills, each with its service's own status.
    var connections: [ConnectionItem] {
        let services = connectionServices
        return Connections.items(status: services.mapValues(\.pillStatus), detail: services.mapValues(\.pillDetail))
    }
    var dropResult: DropResult?
    /// Text for the composer (a drop, "Ask about it", a connection's "Ask Kobe about …").
    /// Kept between launches (in settings) unless it looks like a key or is very long (`DraftRules`).
    var composerDraft: String {
        get { transientDraft }
        set {
            transientDraft = newValue
            settings.composerDraft = DraftRules.persistable(newValue) ? newValue : ""
        }
    }
    /// The draft as typed (seeded from settings at launch): the only copy when it may not be persisted.
    private var transientDraft = ""
    /// Claude Code cards, oldest first: the first is on screen, the others wait their turn. A newer card never
    /// replaces one that still waits for an answer.
    private(set) var claudeCards: [ClaudeCard] = []
    var claudeCard: ClaudeCard? { claudeCards.first }
    /// What each Claude Code project is doing, and which one reported last: the left wing shows that one.
    private var claudeSteps: [String: ClaudeStep] = [:]
    private var lastStepProject: String?
    var claudeStep: (project: String, step: ClaudeStep)? {
        guard let project = lastStepProject, let step = claudeSteps[project] else { return nil }
        return (project, step)
    }
    /// The Allow hotkey waits until a card on screen has shown the request to its end (the button always works).
    /// The cards report themselves (`AllowLockReporter`); no card on screen is locked.
    private(set) var claudeLock = AllowLock()
    private(set) var approvalLock = AllowLock()
    var claudeAllowLocked: Bool { claudeLock.locked }
    var approvalAllowLocked: Bool { approvalLock.locked }
    /// When the request now on screen appeared: a hotkey pressed within 0.3 s of that was meant for something else.
    @ObservationIgnored private var armedAt: Date = .distantPast
    var claudeHooksInstalled = false
    /// The installed hooks were written for another "Claude Code waits" value: re-install them.
    var claudeHooksOutOfDate = false
    var claudeListening = false
    var quickAnswer = ""
    /// A reply that finished while the notch was closed, for the band.
    var replyNotice: String?
    var quickAsking = false
    /// Approvals answered today, for Settings › Home.
    var approvalsToday = 0

    /// Kobe's work page: Kobe Agent's cron jobs, read only while the page is open (on appear and ↻).
    private(set) var jobs: [HermesJob] = []
    private(set) var jobsLoading = false
    private(set) var jobsError: String?
    /// A Stop on one of Kobe Agent's own runs that didn't go, shown on its row until the next Stop.
    private(set) var stopErrors: [String: String] = [:]
    /// The app's own runs, for the work page: what was asked and when.
    private var chatTurn: (text: String, startedAt: Date)?
    private var quickAskRun: (text: String, startedAt: Date)?
    /// Held so the work page's Stop can close the quick ask's stream (Hermes then interrupts the run).
    @ObservationIgnored private var quickAskTask: Task<Void, Never>?

    @ObservationIgnored private var claudeServer: ClaudeSocketServer?
    @ObservationIgnored private var keepAwakeTimer: Timer?
    /// The reply the band and the voice last announced, so a turn is announced once.
    @ObservationIgnored private var lastAnnouncedReply: String?

    /// The exchange folder: where drops land and the pages' snapshots, requests and results live.
    var exchangeRoot: URL { snapshotRoot ?? SnapshotFolder.root }
    @ObservationIgnored private let snapshotRoot: URL?

    static let dataFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(Brand.dataFolderName)", isDirectory: true)

    /// `secrets` backs every key (Kobe's, the services', WhatsApp's): `--demo` passes `InMemorySecrets` so nothing
    /// touches the real Keychain. `api` stands in for Kobe in the chat and the connection check, and `snapshotRoot`
    /// for the exchange folder the pages read (both for the tests; nil: the real ones).
    init(settings: AppSettings = AppSettings(), secrets: any SecretStoring = KeychainSecrets(),
         api: (any HermesAPI)? = nil, snapshotRoot: URL? = nil,
         calendar: (any CalendarSource)? = nil, scripts: (any ScriptRunner)? = nil, demoMac: Bool = false,
         shell: (any ShellRunner)? = nil, home: URL? = nil, session: URLSession? = nil) {
        self.settings = settings
        transientDraft = settings.composerDraft
        // One exchange folder for drops, snapshots, requests and results. A test's folder is plain (same user).
        SnapshotFolder.configure(snapshotRoot.map { ExchangeSettings(folder: $0.path, shared: false) } ?? settings.exchange)
        self.snapshotRoot = snapshotRoot
        let key = HermesKey(store: secrets)
        self.key = key
        keys = ServiceKeys(store: secrets)
        client = HermesClient(baseURL: { [settings] in settings.currentServerURL }, key: { [key] in key.load() },
                              session: session ?? .kobeLoopback)
        let resolvedAPI: any HermesAPI = api ?? client
        self.api = resolvedAPI
        connection = Connection(api: resolvedAPI, keyIsSet: { [key] in key.isSet })
        chats = ChatStore(api: resolvedAPI, systemPrompt: { [settings] in
            // Another user's Hermes: the person manages its SOUL.md, so Kobe injects nothing.
            settings.engineSeparateUser || settings.profileInSoul ? nil
                : ProfileFiles.systemPrompt(Profile(name: settings.assistantName, role: settings.assistantRole,
                                                    tone: settings.assistantTone))
        })
        snapshots = SnapshotStore(root: snapshotRoot)
        island = IslandModel(geometry: .current() ?? .placeholder)
        let report: (ServiceEvent) -> Void = { [events] event in events.handler?(event) }
        stripe = StripeService(keys: keys, report: report)
        github = GitHubService(keys: keys, report: report)
        vercel = VercelService(keys: keys, report: report)
        whatsapp = WhatsAppController(secrets: secrets, report: report)
        mac = MacConnectors(settings: settings,
                            calendar: calendar ?? (demoMac ? DemoCalendar() : EventKitReader()),
                            scripts: scripts ?? (demoMac ? DemoScripts() : AppleEventsReader()),
                            isRunning: demoMac ? { _ in true }
                                               : { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
                            write: { snapshot in
                                switch snapshot {
                                case .mail(let s): SnapshotWriter.write(s)
                                case .agenda(let s): SnapshotWriter.write(s)
                                case .reminders(let s): SnapshotWriter.write(s)
                                case .notes(let s): SnapshotWriter.write(s)
                                case .plain(let s): SnapshotWriter.write(s)
                                }
                            },
                            lastFile: { try? Data(contentsOf: SnapshotFolder.url($0)) },
                            open: demoMac ? { _ in true } : { NSWorkspace.shared.open($0) },
                            watchesWorkspace: !demoMac, alwaysOn: demoMac)
        let shell: any ShellRunner = shell ?? ProcessShell()
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.shell = shell
        self.home = home
        engine = EngineService(settings: settings, shell: shell, key: key, session: session ?? .kobeLoopback, home: home,
                               demo: shell is DemoShell)
        brain = BrainService(settings: settings, shell: shell, secrets: secrets, home: home)
        connect = ConnectService(app: self, engine: engine, brain: brain, shell: shell, home: home,
                                 agentSource: Bundle.main.resourceURL?.appendingPathComponent("agent"))
        actions = ShimActionSink(app: self)
        agentActions = RequestFileActionSink(root: snapshotRoot)
        actionQueue = ActionQueue { [weak self] action in
            guard let self else { return .failure(ActionError(message: "Kobe is closing")) }
            return await self.actions.perform(action)
        }
    }

    /// The in-app service behind a page, for its ↻ (the shim).
    func service(for id: WidgetID) -> (any ConnectionService)? {
        switch id {
        case .stripe: stripe
        case .github: github
        case .vercel: vercel
        case .whatsapp: whatsapp
        default: nil
        }
    }

    /// Who runs a connector right now: Kobe Agent while its file is fresh, else the app's shim.
    func owner(_ id: WidgetID) -> SnapshotSource {
        Handover.owner(existing: snapshots.envelopes[id].map { ($0.source, $0.updatedAt) }, id: id)
    }

    /// A page with ↻: its connector runs in the app or in Kobe Agent (Google only ever runs in Kobe Agent, so its
    /// ↻ stays while the agent's file is stale, after a sleep or a stop).
    func canRefresh(_ id: WidgetID) -> Bool {
        if let kind = MacKind(id) { return settings.isOn(kind) || mac.alwaysOn }
        return id == .work || service(for: id) != nil || snapshots.envelopes[id]?.source == .agent
    }

    /// Where ↻ goes: Kobe Agent while it owns the connector, or always for one the app can't run.
    private func refreshesThroughAgent(_ id: WidgetID) -> Bool {
        owner(id) == .agent || service(for: id) == nil
    }

    /// ↻ or ⌘R on a page: a request to Kobe Agent when it runs the connector, else the service's own non-resetting
    /// refresh; the icon spins until the file moves.
    func refreshPage(_ id: WidgetID) {
        if id == .work { refreshWork(); return }
        // A second click while it still spins asks nothing more.
        guard canRefresh(id), refreshes.start(id, current: snapshots.envelopes[id]?.updatedAt) else { return }
        // The Mac apps are read here, never by Kobe Agent.
        if let kind = MacKind(id) { mac.refresh(kind); return }
        let sink: any ActionSink = refreshesThroughAgent(id) ? agentActions : actions
        Task { _ = await sink.perform(.refresh(id)) }
    }

    /// Now's Reply: the WhatsApp page, straight on that chat's conversation.
    func openWhatsApp(chat: String) {
        whatsappChat = chat
        openPage(.whatsapp)
    }

    /// A background event: the pill's badge (unless its card is open), a sound, and the band for a few seconds.
    func report(_ event: ServiceEvent) {
        let page = WidgetID(rawValue: event.pill)
        let cardOpen = island.expanded && page.map { island.overlay == .page($0) } == true
        if !cardOpen, let page { serviceBadges[page] = event.kind }
        switch event.sound {
        case .finish: Sounds.play(.done, settings: settings)
        case .error: Sounds.play(.error, settings: settings)
        case .question: Sounds.play(.needsYou, settings: settings)
        case .pop: Sounds.play(.pop, settings: settings)
        case .silent: break
        }
        guard !cardOpen else { return }
        serviceNotice = event
        controller?.notify()
        noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            self.serviceNotice = nil
            if self.island.phase == .compact, self.banner == nil, !self.island.hovering { self.controller?.close() }
        }
    }

    /// Stops every connection's timers and processes (at quit).
    func stopConnections() {
        connectionServices.values.forEach { $0.stop() }
        mac.stop()
        snapshots.stop()
    }

    // MARK: Derived state

    var isBusy: Bool { chats.isBusy || quickAsking }

    /// The notification band's content, by priority: Kobe waiting, Claude Code, a reply.
    var banner: Banner? {
        // The band shows no body, so the hotkeys open the notch on the request instead of answering it.
        let answer = "⌥⌘Y to review"
        if chats.pendingApproval != nil {
            return Banner(icon: .warningCircleFill, tint: K.amber, title: settings.copy.needsYou, detail: answer, waiting: true)
        }
        switch claudeCard?.event {
        case .finished(let project, _)?:
            return Banner(icon: .terminalWindowFill, tint: K.text2, title: "Claude · \(project)", detail: "Finished", waiting: false)
        case .permission(let permission)?:
            return Banner(icon: .shieldWarningFill, tint: K.amber, title: "Claude · \(permission.project)", detail: answer, waiting: true)
        case .question(let question)?:
            return Banner(icon: .shieldWarningFill, tint: K.lime, title: "Claude asks", detail: question.question, waiting: true)
        default:
            break
        }
        if let reply = replyNotice {
            return Banner(icon: .sparkleFill, tint: K.lime, title: settings.copy.replied, detail: reply, waiting: false)
        }
        if let event = serviceNotice {
            let tint: Color = switch event.kind {
            case .finished: K.green
            case .error: K.red
            case .attention: K.amber
            }
            return Banner(icon: Connections.icon(event.pill), tint: tint, title: Connections.name(event.pill), detail: event.detail, waiting: false)
        }
        return nil
    }

    /// An approval or a Claude Code permission/question is waiting: the island stays open for it.
    var needsAnswer: Bool {
        if chats.pendingApproval != nil { return true }
        return claudeCards.contains { $0.event.waitsForAnswer }
    }

    // MARK: Onboarding

    /// Onboarding's brain step: the person kept the brain Hermes already has, so Kobe hands over no key.
    /// Persisted, so a quit between the brain step and Connecting doesn't hand over a key nobody chose.
    var brainKeptFromHermes: Bool {
        get { settings.brainKeptFromHermes }
        set { settings.brainKeptFromHermes = newValue }
    }

    /// First launch on a Mac that isn't set up: the window opens by itself.
    var onboardingShouldOpen: Bool {
        OnboardingMachine.shouldOpenAtLaunch(settings.onboarding, engineKeySet: key.isSet)
    }

    func completeStep(_ step: OnboardingStep) {
        settings.onboarding.completed.insert(step)
    }

    /// "Open the notch": the window is done for good and Home opens.
    func finishOnboarding() {
        completeStep(.ready)
        settings.onboarding.done = true
        show(.home)
    }

    /// Settings › Engine: a new private key in the engine's config and the Keychain, then the engine restarts.
    /// Returns what went wrong, or nil. The engine is connected from Settings, so first-run won't open again.
    /// A gateway Kobe didn't start is left alone (its key too): the person restarts it themselves.
    @discardableResult
    func rotateEngineKey(healthTimeout: Duration = .seconds(20)) async -> String? {
        if settings.engineSeparateUser { return EngineService.elsewhereMessage }
        if await engine.gatewayOwner() == .someoneElse { return EngineService.foreignGatewayMessage }
        do {
            try await engine.ensureApiServer(rotate: true)
            finishOnboardingFromSettings()
            try await engine.startGateway()
        } catch { return error.localizedDescription }
        guard await engine.waitForHealth(timeout: healthTimeout) else {
            reconnect()
            return "The engine didn't answer with the new key in time. Press Check in a moment."
        }
        reconnect()
        await engine.check()
        return nil
    }

    /// Settings › Your assistant: rewrites `profile.md`, and `SOUL.md` only when the marker rule allows.
    /// Returns what went wrong, or nil.
    @discardableResult
    func rewriteProfile() async -> String? {
        // Another user's Hermes keeps its own files: the profile reaches it through each new session.
        if settings.engineSeparateUser { return nil }
        do { try connect.writePersonality() } catch { return error.localizedDescription }
        return nil
    }

    // MARK: Service keys

    /// Settings' Save for a Stripe, GitHub or Vercel key: the Keychain first, then Kobe Agent's copy.
    @discardableResult
    func saveServiceKey(_ raw: String, for service: Service) async -> Bool {
        guard keys.save(raw, for: service) else { return false }
        await syncAgentSecrets()
        return true
    }

    func removeServiceKey(_ service: Service) async {
        keys.remove(service)
        await syncAgentSecrets()
    }

    /// Mirrors the service keys into `~/.hermes/kobe/secrets` once Kobe Agent is installed there (same user only):
    /// a file for each key, none for a service without one.
    func syncAgentSecrets() async {
        guard !settings.engineSeparateUser,
              shell.fileExists(home.appendingPathComponent(".hermes/kobe").path) else { return }
        try? await AgentInstaller.syncSecrets(home: home, serviceKeys: keys, shell: shell)
    }

    /// The exchange settings changed (Hermes runs as another user): re-point the folder and the snapshot watcher.
    func applyExchangeSettings() {
        SnapshotFolder.configure(settings.exchange)
        snapshots.restart()
    }

    /// The engine connected from Settings, so the first-run window doesn't need to open by itself.
    func finishOnboardingFromSettings() {
        settings.onboarding.finishedFromSettings = true
    }

    /// Home's "Set up again": the first-run progress starts over (the caller opens the window).
    func resetOnboarding() {
        settings.onboarding = OnboardingProgress()
    }

    // MARK: The notch

    /// Opens a tab in the notch (it shows even when "Show in the notch" is off, then hides again).
    func show(_ tab: IslandTab) { controller?.show(tab) }

    func showOverlay(_ overlay: IslandOverlay) { controller?.showOverlay(overlay) }

    func closeSurface() { controller?.close() }

    /// A strip capsule, ⌘n or a Home pill: K is Home, everything else its page (opening it clears its badge).
    func openPage(_ id: WidgetID) {
        guard id != .now else { goHome(); return }
        serviceBadges[id] = nil
        showOverlay(.page(id))
        // Opening a Mac page reads it (Mail and Notes only if they run: the controller checks).
        if let kind = MacKind(id), canRefresh(id) { mac.refresh(kind) }
    }

    /// Home, optionally with the caret in its composer (where a drop's message waits).
    func goHome(focusComposer: Bool = false) {
        show(.home)
        // A drop's message, refused files or the caret request are in the chat: never behind the rail.
        unfoldChat(dropPending: dropResult != nil, focusRequested: focusComposer)
        guard focusComposer else { return }
        composerFocusPending = true
        controller?.takeKeyboard()
    }

    /// "New chat" (the menu bar, Settings, the chats list): an empty chat on Home, the caret in its composer.
    func newChat() {
        chats.newChat()
        goHome(focusComposer: true)
    }

    /// A chat picked from a list: it opens on Home, the caret in its composer.
    func openChat(_ session: HermesSession) {
        Task { await chats.open(session) }
        goHome(focusComposer: true)
    }

    /// Quick ask's "Open in chat": the "Quick ask" chat on Home, the caret in its composer.
    func openQuickAskInChat() {
        Task { await chats.openQuickAsk() }
        goHome(focusComposer: true)
    }

    // MARK: Start

    func start(claude: Bool = true) {
        Task { await connection.check(); await refreshAfterConnect() }
        startTracking()
        // ⌃⌥Space from any app opens quick ask (Carbon hot key: no permission needed).
        HotKeyCenter.shared.register(.quickAsk, keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] pressed in
            guard pressed, let self else { return }
            let open = self.island.overlay == .quickAsk && self.island.expanded
            if open { self.closeSurface() } else { self.showOverlay(.quickAsk) }
        }
        snapshots.start()
        mac.start()
        // What each connection knows at launch (not set up without a key), before its first poll.
        connectionServices.values.forEach { $0.writeSnapshot() }
        guard claude else { return }
        events.handler = { [weak self] event in self?.report(event) }
        connectionServices.values.forEach { $0.start() }
        // The login item is only ever registered after the user chose it in Settings (the default stays "on" as a
        // preference, not as a registration). A choice made while running from a build folder is applied here.
        if settings.launchAtLogin, launchAtLoginChosen { LoginItem.set(true) }
        startClaudeServer()
        refreshClaudeHookState()
    }

    /// The model's own watchers: chat errors, Voice, finished replies, approvals. Part of `start`; the tests call it
    /// alone (no hot keys, services or socket).
    func startTracking() {
        trackCopy()
        trackChatErrors()
        trackVoice()
        trackReplies()
        trackApproval()
    }

    func refreshAfterConnect() async {
        guard connection.isConnected else { return }
        await chats.refreshSessions()
        await refreshConnections()
    }

    func refreshConnections() async {
        await connection.check()
    }

    /// The assistant's name reaches the chat store and the client (their notices and errors) whenever it changes.
    private func trackCopy() {
        let copy = withObservationTracking { settings.copy } onChange: { [weak self] in
            Task { @MainActor in self?.trackCopy() }
        }
        chats.copy = copy
        let client = client
        Task { await client.setCopy(copy) }
    }

    /// A chat request that fails with offline or a refused key updates the connection (wing, status, composer)
    /// and, while offline, retries with backoff until Kobe answers again.
    private func trackChatErrors() {
        let error = withObservationTracking { chats.lastError } onChange: { [weak self] in
            Task { @MainActor in self?.trackChatErrors() }
        }
        guard let error, error == .offline || error == .unauthorized || error == .noKey else { return }
        Task {
            await connection.noteFailure(error)
            await refreshAfterConnect()
        }
    }

    /// Voice on: start Kokoro's helper; off: stop it.
    private func trackVoice() {
        let on = withObservationTracking { settings.voiceOn } onChange: { [weak self] in
            Task { @MainActor in self?.trackVoice() }
        }
        if on { Task { await voice.prepare() } } else { voice.shutdown() }
    }

    /// Each finished reply: the "Kobe replied" band and the done sound while the notch is closed, and read aloud
    /// while Voice is on. The store sets `lastReply` before it clears `isBusy`, so both are watched and a reply is
    /// announced once, when the turn is over.
    private func trackReplies() {
        let (reply, busy) = withObservationTracking { (chats.lastReply, chats.isBusy) } onChange: { [weak self] in
            Task { @MainActor in self?.trackReplies() }
        }
        guard !busy, let reply, !reply.isEmpty, reply != lastAnnouncedReply else { return }
        lastAnnouncedReply = reply
        if !island.expanded, !quickAsking {
            replyNotice = String(reply.split(separator: "\n").first ?? "").prefix(60).description
            if island.overlay == .claude { island.overlay = .none }
            island.tab = .home
            unfoldChat(replyNotice: true)
            controller?.notify()
            Sounds.play(.done, settings: settings)
            let shown = replyNotice
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(settings.autoCloseSeconds)) { [weak self] in
                guard let self, self.replyNotice == shown, !self.island.expanded, !self.island.hovering else { return }
                self.replyNotice = nil
                self.controller?.close()
            }
        }
        if settings.voiceOn { voice.speak(reply, settings: settings) }
    }

    /// A new Hermes approval arms the hotkeys afresh; its Allow lock comes from the card that shows it.
    private func trackApproval() {
        let id = withObservationTracking { chats.pendingApproval?.id } onChange: { [weak self] in
            Task { @MainActor in self?.trackApproval() }
        }
        guard id != nil else { return }
        // The approval card lives in the chat: a folded chat unfolds so it is never hidden.
        unfoldChat(needsAnswer: true)
        arm()
    }

    /// Unfolds Home's chat when something waits in it (`HomeLayout.shouldUnfold`).
    private func unfoldChat(needsAnswer: Bool = false, dropPending: Bool = false, replyNotice: Bool = false,
                            focusRequested: Bool = false) {
        if HomeLayout.shouldUnfold(needsAnswer: needsAnswer, dropPending: dropPending, replyNotice: replyNotice,
                                   focusRequested: focusRequested) {
            if island.homeMode == .reading { island.homeMode = .split }
        }
    }

    /// Amounts as the settings ask: "€40.50", or "€•••" when hidden (the Stripe page's eye, ⌘H).
    func money(_ minor: Int, _ currency: String) -> String {
        MoneyMask.money(minor, currency, hidden: settings.hideAmounts)
    }

    /// A line of text with its amounts hidden when the settings ask (Now rows, headlines).
    func moneyText(_ text: String) -> String {
        settings.hideAmounts ? MoneyMask.mask(text) : text
    }

    /// The chat pane's fold button: Now gets the width, unless something waits in the chat.
    func foldChat() {
        guard !needsAnswer else { return }
        island.homeMode = .reading
    }

    /// Typing on Home folds Now when the setting asks for it.
    func composerTyped() {
        guard !composerDraft.isEmpty, island.overlay == .none || island.overlay == .page(.now) else { return }
        island.homeMode = HomeLayout.afterTyping(island.homeMode, foldOnType: settings.foldNowOnType)
    }

    /// The mode Home opens in (`HomeLayout.opening`).
    var homeOpening: HomeMode {
        HomeLayout.opening(settings.homeStart, needsYou: nowContent.0.needsYou.count, needsAnswer: needsAnswer,
                           chatWaiting: HomeLayout.shouldUnfold(needsAnswer: false, dropPending: dropResult != nil,
                                                                replyNotice: replyNotice != nil,
                                                                focusRequested: composerFocusPending))
    }

    /// After the key is saved in Settings.
    func reconnect() {
        Task { await connection.check(); await refreshAfterConnect() }
    }

    // MARK: Chats

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        voice.stop()
        composerDraft = ""
        chatTurn = (text, Date())
        island.tab = .home
        island.overlay = .none
        // The answer appears in the chat, so a folded chat unfolds.
        if island.homeMode == .reading { island.homeMode = .split }
        // The turn belongs to the store, not to a view, so closing the island never interrupts Kobe.
        Task {
            if await chats.send(text) { settings.returnHintsShown += 1 } else { composerDraft = text }
        }
    }

    /// Puts the last message back in the composer to change and send again.
    func editLastMessage() {
        guard let text = chats.lastUserLine?.text else { return }
        composerDraft = text
        composerFocusPending = true
        controller?.takeKeyboard()
    }

    func retryLastMessage() {
        Task { _ = await chats.retry() }
    }

    func quickAsk(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !quickAsking else { return }
        voice.stop()
        quickAsking = true
        quickAnswer = ""
        quickAskRun = (text, Date())
        // App-owned task: a view's task would be cancelled when it disappears, and Hermes would stop answering.
        // Only the work page's Stop cancels it.
        quickAskTask = Task {
            quickAnswer = await chats.quickAsk(text)
            quickAsking = false
            quickAskTask = nil
            Sounds.play(.done, settings: settings)
        }
    }

    /// ⌥⌘Y and ⌥⌘N, from any app, registered only while a Hermes approval or a Claude Code permission waits. They
    /// answer only the request whose card is on screen; with just the band showing they open the notch on it.
    func updateApprovalHotKeys() {
        let center = HotKeyCenter.shared
        // Any permission in the queue counts: it will be the card on screen once the ones before it are done.
        let claudePermission = claudeCards.contains { if case .permission = $0.event { true } else { false } }
        guard chats.pendingApproval != nil || claudePermission else {
            center.unregister(.approve)
            center.unregister(.decline)
            return
        }
        guard !center.isRegistered(.approve) else { return }
        center.register(.approve, keyCode: kVK_ANSI_Y, modifiers: cmdKey | optionKey) { [weak self] pressed in
            if pressed { self?.hotKey(allow: true) }
        }
        center.register(.decline, keyCode: kVK_ANSI_N, modifiers: cmdKey | optionKey) { [weak self] pressed in
            if pressed { self?.hotKey(allow: false) }
        }
    }

    /// The request whose card is on screen right now. The Hermes approval card sits above whatever view is open,
    /// so it comes first, except on Home with the chat folded (the card lives in the chat): then nil, and the hotkey
    /// opens the work page on it (`review()`). A Claude permission counts only while its card is the open view.
    var hotKeyTarget: HotKeyTarget? {
        guard island.expanded else { return nil }
        if chats.pendingApproval != nil {
            let onHome = island.overlay == .none || island.overlay == .page(.now)
            return onHome && island.homeMode == .reading ? nil : .approval
        }
        // The work page shows the first card's permission in full, like the Claude card does.
        if island.overlay == .claude || island.overlay == .page(.work), case .permission? = claudeCard?.event { return .claude }
        return nil
    }

    /// The card now on screen just appeared (or the notch just opened): hotkeys count 0.3 s later.
    func arm() { armedAt = Date() }

    private var hotKeyArmed: Bool { Date().timeIntervalSince(armedAt) >= 0.3 }

    /// ⌥⌘Y / ⌥⌘N (internal for the tests).
    func hotKey(allow: Bool) {
        guard let target = hotKeyTarget else { review(); return }
        guard hotKeyArmed else { return }
        switch (target, allow) {
        case (.approval, true): if !approvalAllowLocked { answerApproval(.once) }
        case (.approval, false): answerApproval(.deny)
        case (.claude, true): if !claudeAllowLocked { answerClaude(.allow) }
        case (.claude, false): answerClaude(.deny)
        }
    }

    /// Opens the notch on what waits, to read it before answering: Kobe's work page, the home of every approval,
    /// where the waiting requests come first and in full. The request is new on screen, so the hotkeys re-arm.
    func review() {
        arm()
        controller?.openForAnswer()
    }

    /// A card showing Kobe's approval: locked while its end is unseen, nil once it left the screen.
    func reportApprovalLock(_ card: UUID, locked: Bool?) { approvalLock.report(card, locked: locked) }
    /// The same for a card showing a Claude Code permission.
    func reportClaudeLock(_ card: UUID, locked: Bool?) { claudeLock.report(card, locked: locked) }

    func answerApproval(_ choice: ApprovalChoice) {
        guard chats.pendingApproval != nil else { return }
        approvalsToday += 1
        Task { await chats.answer(choice) }
    }

    // MARK: Home's Now

    /// Kobe Agent's own list when it is fresh; otherwise the shim's (`NowRanker`), dated by its newest input.
    var nowContent: (NowSnapshotData, Date?) {
        let s = snapshots
        if let now = s.now, case .fresh = s.freshness(.now) { return (now.data, now.updatedAt) }
        let data = NowRanker.compose(stripe: s.stripe, whatsapp: s.whatsapp, github: s.github, vercel: s.vercel,
                                     agenda: s.agenda, reminders: s.reminders)
        return (data, NowRanker.updatedAt(stripe: s.stripe, whatsapp: s.whatsapp, github: s.github, vercel: s.vercel,
                                          agenda: s.agenda, reminders: s.reminders))
    }

    // MARK: Kobe's work

    /// The runs the app started itself: the chat turn or the quick ask in progress (one at a time: `isBusy`).
    var appRuns: [WorkRun] {
        if quickAsking, let run = quickAskRun {
            return [WorkRun(id: "quick-ask", name: String(run.text.prefix(80)), startedAt: run.startedAt,
                            progress: "Quick ask", stoppable: quickAskTask != nil)]
        }
        guard chats.isBusy, let turn = chatTurn else { return [] }
        let step = chats.lines.last { $0.role == .tool }?.text
        let place = chats.current.map { "Chat · \($0.displayTitle)" } ?? "Chat"
        return [WorkRun(id: "chat", name: String(turn.text.prefix(80)), startedAt: turn.startedAt,
                        progress: [place, step].compactMap { $0 }.joined(separator: " · "), stoppable: true)]
    }

    /// What waits for an answer, in the order the hotkeys would take it: Kobe's approval first (its card sits above
    /// every view), then the Claude Code cards; only the first card can be answered, the others wait their turn.
    var workWaiting: [WorkWaiting] {
        var waiting: [WorkWaiting] = []
        if let request = chats.pendingApproval {
            waiting.append(WorkWaiting(id: Self.approvalWaitingID, title: settings.copy.needsYou,
                                       detail: request.description ?? request.command ?? "", answerable: true))
        }
        for (index, card) in claudeCards.enumerated() {
            switch card.event {
            case .permission(let permission):
                waiting.append(WorkWaiting(id: card.id.uuidString, title: "Claude Code · \(permission.project)",
                                           detail: "\(permission.title): \(permission.body)", project: permission.project,
                                           answerable: index == 0))
            case .question(let question):
                waiting.append(WorkWaiting(id: card.id.uuidString, title: "Claude Code · \(question.project)",
                                           detail: question.question, project: question.project, answerable: index == 0))
            default:
                continue
            }
        }
        return waiting
    }

    static let approvalWaitingID = "kobe-approval"

    /// Claude Code sessions at work, from their last hook event.
    var workSessions: [WorkSession] {
        claudeSteps.keys.sorted().compactMap { project in claudeSteps[project].map { WorkSession(project: project, step: $0.label) } }
    }

    func workSections(now: Date) -> [WorkSection] {
        WorkFeed.compose(appRuns: appRuns, snapshot: snapshots.work?.data, jobs: jobs, waiting: workWaiting,
                         sessions: workSessions, now: now)
    }

    /// The work page's appear and ↻ / ⌘R: the cron list again. Never polled in the background.
    func refreshWork() {
        guard !jobsLoading else { return }
        jobsLoading = true
        Task {
            do {
                jobs = try await client.jobs()
                jobsError = nil
            } catch {
                jobsError = ChatStore.describe(error, copy: settings.copy)
            }
            jobsLoading = false
        }
    }

    /// Stop on a run the app started: closing its stream is how Hermes interrupts a run.
    func stopAppRun(_ id: String) {
        switch id {
        case "chat": chats.stop()
        case "quick-ask": quickAskTask?.cancel()
        default: break
        }
    }

    /// Stop on one of Kobe Agent's own runs goes to the action sink; a refusal shows on its row.
    func stopAgentRun(_ id: String) {
        stopErrors[id] = nil
        Task {
            if case .failure(let error) = await actions.perform(.stopRun(id: id)) { stopErrors[id] = error.message }
        }
    }

    // MARK: Drops

    func dropFiles(_ urls: [URL]) -> Bool {
        let result = DropBox(root: exchangeRoot).accept(urls)
        // Copied files go into Home's composer after whatever was already typed; refused ones are listed on Home.
        if !result.copied.isEmpty { composerDraft = DropBox.message(for: result.copied, text: composerDraft) + "\n\n" }
        var refused = result
        refused.copied = []
        dropResult = result.refused.isEmpty ? nil : refused
        goHome(focusComposer: true)
        return !result.copied.isEmpty
    }

    /// Dropped text goes into Home's field like a file's message, ready to edit or send.
    func dropText(_ text: String) -> Bool {
        composerDraft = text
        goHome(focusComposer: true)
        return true
    }

    // MARK: Keep awake

    func setKeepAwake(minutes: Int?) {
        if let minutes {
            keepAwake.activate(minutes: minutes, allowDisplaySleep: false)
            keepAwakeTimer?.invalidate()
            // "Until you turn it off" has no end time: nothing to check, no timer.
            guard keepAwake.endsAt != nil else { return }
            // The only timer while resting: checks the end time every 30 s, only while a timed keep awake is on.
            keepAwakeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.keepAwake.checkExpiry()
                    if !self.keepAwake.isActive { self.keepAwakeTimer?.invalidate() }
                }
            }
        } else {
            keepAwake.deactivate()
            keepAwakeTimer?.invalidate()
        }
    }

    func toggleKeepAwake() {
        keepAwake.isActive ? setKeepAwake(minutes: nil) : setKeepAwake(minutes: 60)
    }

    // MARK: Login item

    /// Settings › General: the toggle registers or removes the login item, and remembers that the user chose.
    var launchAtLoginChosen: Bool { UserDefaults.standard.bool(forKey: "launchAtLoginChosen") }

    func setLaunchAtLogin(_ on: Bool) {
        settings.launchAtLogin = on
        UserDefaults.standard.set(true, forKey: "launchAtLoginChosen")
        LoginItem.set(on)
    }

    // MARK: Claude Code

    var hookPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/kobe-hook").path }
    static var claudeSettingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }

    func refreshClaudeHookState() {
        let text = (try? String(contentsOf: Self.claudeSettingsURL, encoding: .utf8)) ?? ""
        claudeHooksInstalled = text.contains(hookPath)
        let installedWait = ClaudeSettingsInstaller.installedWait(settings: text, hookPath: hookPath)
        claudeHooksOutOfDate = installedWait.map { $0 != settings.claudeWait } ?? false
    }

    private func startClaudeServer() {
        let server = ClaudeSocketServer(path: Self.dataFolder.appendingPathComponent("claude.sock").path,
                                        answerTimeout: TimeInterval(settings.claudeWait + 30)) { [weak self] event, reply in
            Task { @MainActor in self?.handleClaude(event, reply: reply) }
        }
        do {
            try server.start()
            claudeServer = server
            claudeListening = true
        } catch {
            claudeListening = false
        }
    }

    /// Steps are kept per project, so one session's Stop or end never clears what another is doing.
    private func handleClaude(_ event: ClaudeEvent, reply: ClaudeSocketServer.Reply?) {
        switch event {
        case .sessionStarted(let project):
            step(project, .working)
        case .step(let project, let step):
            self.step(project, step)
        case .ended(let project), .finished(let project, _):
            claudeSteps[project] = nil
            if lastStepProject == project { lastStepProject = claudeSteps.keys.sorted().first }
            if case .finished = event {
                enqueue(ClaudeCard(event: event, reply: nil))
                Sounds.play(.done, settings: settings)
            }
        case .permission, .question:
            enqueue(ClaudeCard(event: event, reply: reply))
            Sounds.play(.needsYou, settings: settings)
        }
    }

    private func step(_ project: String, _ step: ClaudeStep) {
        claudeSteps[project] = step
        lastStepProject = project
    }

    /// Cards queue: the oldest waiting one stays on screen until answered, the next follows. A project's newer
    /// "finished" replaces its older one (no answer is lost); nothing else is ever replaced.
    private func enqueue(_ card: ClaudeCard) {
        let shown = claudeCards.first?.id
        if case .finished = card.event {
            claudeCards.removeAll { if case .finished = $0.event, $0.project == card.project { true } else { false } }
        }
        claudeCards.append(card)
        if card.event.waitsForAnswer {
            // The hook gives up after claudeWait seconds and Claude asks in its own UI: the card goes too, shown
            // or still queued.
            let id = card.id
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(settings.claudeWait) + 1) { [weak self] in
                guard let self, let index = self.claudeCards.firstIndex(where: { $0.id == id }) else { return }
                if index == 0 { self.answerClaude(.none) } else { self.claudeCards.remove(at: index).reply?(.none) }
            }
        }
        // The card on screen changed (first ever, or a replaced "finished" that was showing): present the new first.
        if claudeCards.first?.id != shown { present() }
    }

    /// The first card goes on screen: as the band while the notch is closed, as the card itself once open.
    private func present() {
        guard !claudeCards.isEmpty else { return }
        claudeCards[0].shownAt = Date()
        arm()
        updateApprovalHotKeys()
        // A permission is answered on Kobe's work page (spec §6.10); a question and "finished" keep their card.
        if case .permission = claudeCards[0].event { island.overlay = .page(.work) } else { island.overlay = .claude }
        controller?.notify()
        if !claudeCards[0].event.waitsForAnswer { scheduleAutoClose(claudeCards[0].id) }
    }

    /// A finished card folds after the chosen 10/15/30 s, unless the pointer is over it or the island is pinned.
    private func scheduleAutoClose(_ id: UUID, after delay: TimeInterval? = nil) {
        let wait = delay ?? TimeInterval(settings.autoCloseSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, let card = self.claudeCard, card.id == id else { return }
            let shown = Date().timeIntervalSince(card.shownAt)
            if AutoClose.shouldFold(overlay: .finished, shownFor: shown, setting: self.settings.autoCloseSeconds,
                                    hovering: self.island.hovering, pinned: self.island.pinned) {
                self.dismissClaude()
            } else {
                self.scheduleAutoClose(id, after: 2)
            }
        }
    }

    func answerClaude(_ answer: ClaudeAnswer) {
        guard let card = claudeCard else { return }
        card.reply?(answer)
        dismissClaude()
    }

    /// The card on screen goes; the next waiting one takes its place, if any.
    func dismissClaude() {
        guard !claudeCards.isEmpty else { return }
        claudeCards.removeFirst()
        if !claudeCards.isEmpty { present(); return }
        // A permission that went before the notch was opened leaves no work page behind for the next open.
        if island.overlay == .claude || (!island.expanded && island.overlay == .page(.work)) { island.overlay = .none }
        // A card that came as the band folds away; one shown inside the open notch just clears.
        if island.phase == .compact, !needsAnswer, !island.hovering { closeSurface() }
    }

    /// Brings the app that runs Claude Code forward.
    func openTerminal(for card: ClaudeCard) {
        let names: [String: String] = ["VS Code": "com.microsoft.VSCode", "Terminal": "com.apple.Terminal", "iTerm": "com.googlecode.iterm2",
                                       "Ghostty": "com.mitchellh.ghostty", "Warp": "dev.warp.Warp-Stable"]
        if case .finished(_, let app?) = card.event, let id = names[app],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        dismissClaude()
    }
}
