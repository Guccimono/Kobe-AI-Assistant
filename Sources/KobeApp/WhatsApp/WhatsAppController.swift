import AppKit
import Foundation
import Intents
import Observation
import KobeKit

/// WhatsApp in the notch. Talks to the local gateway (GOWA, which Kobe can install and
/// start, or OpenWA), receives new messages on a webhook bound to 127.0.0.1, falls back to polling when no webhook
/// comes, and keeps the conversations in memory only: no message is ever written to a log, and everything is
/// forgotten when Kobe quits or the integration is turned off. The one exception is the snapshot file (the chat
/// list with a one-line preview each, `widgets/whatsapp.json`, 0640). Runs only while it is turned on.
@MainActor
@Observable
final class WhatsAppController: ConnectionService {
    static let pill = "whatsapp"
    static let appBundleID = "net.whatsapp.WhatsApp"

    enum Link: Equatable {
        case off
        case connecting
        /// The gateway runs, WhatsApp isn't linked: the QR is shown in Settings.
        case needsQR
        case connected
        case unreachable
        case unauthorized
        case failed(String)

        var label: String {
            switch self {
            case .off: WAText.statusOff
            case .connecting: WAText.statusConnecting
            case .needsQR: WAText.statusNeedsQR
            case .connected: WAText.statusConnected
            case .unreachable: WAText.statusUnreachable
            case .unauthorized: WAText.statusUnauthorized
            case .failed(let why): why
            }
        }
    }

    enum Webhook: Equatable {
        case off
        /// Listening on the port, not yet accepted by the gateway.
        case listening
        /// The gateway accepted the address: messages should come on their own.
        case registered
        /// The gateway refused it (its message): polling instead.
        case refused(String)
        /// The port is taken.
        case portBusy
    }

    @ObservationIgnored let secrets: any SecretStoring
    @ObservationIgnored let report: (ServiceEvent) -> Void
    @ObservationIgnored let settings: WhatsAppSettings
    @ObservationIgnored let gowa = WhatsAppGOWAProcess()
    let installer: WhatsAppGOWAInstaller

    private(set) var inbox = WAInbox()
    private(set) var link: Link = .off
    private(set) var webhook: Webhook = .off
    private(set) var qrPNG: Data?
    /// This account (JID or number), once linked.
    private(set) var me: String?
    /// Whether macOS lets Kobe read the Focus state (nil: not asked yet).
    private(set) var focusReadable: Bool?
    /// A reply on its way.
    private(set) var sending = false
    /// Why the last reply didn't go (shown under the field until the next try).
    private(set) var sendError: String?
    /// A reply is being typed: the island should stay open until it is sent or cleared.
    var hasDraft = false
    /// Unsent replies per chat, kept when Esc goes back to the list (in memory only, like the messages).
    var drafts: [String: String] = [:]
    /// "Show my WhatsApp messages".
    private(set) var enabled: Bool
    var filters: WAFilters {
        didSet { settings.filters = filters }
    }
    /// Failed checks in a row (the gateway down, refusing, unreachable).
    private(set) var failures = 0
    /// Bumped by Settings so views re-read what lives outside observation (UserDefaults, the Keychain).
    private(set) var settingsVersion = 0

    var visibleConversations: [WAConversation] { inbox.visible(filters: filters) }
    var visibleUnread: Int { inbox.visibleUnread(filters: filters) }

    @ObservationIgnored private var provider: (any WhatsAppProvider)?
    @ObservationIgnored private let listener = WhatsAppWebhookListener()
    /// The cadence loop: sleeps until the next tick that has something due (no 5 s wake-up while nothing is).
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var backfilled = false
    @ObservationIgnored private var qrExpiry: Date = .distantPast
    @ObservationIgnored private var lastWebhook: Date?
    @ObservationIgnored private var lastPoll = Date()
    @ObservationIgnored private var lastAnnounce: Date = .distantPast
    @ObservationIgnored private var namingGroups: Set<String> = []
    /// The conversation open in the card: what arrives there is seen, so it isn't unread.
    @ObservationIgnored private(set) var openChat: String?
    @ObservationIgnored private var rateLimit = WARateLimit(limit: 6, window: 60)
    /// Bumped at each start and stop: an answer from before a restart is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(secrets: any SecretStoring = KeychainSecrets(), report: @escaping (ServiceEvent) -> Void) {
        self.secrets = secrets
        self.report = report
        let settings = WhatsAppSettings(secrets: secrets)
        self.settings = settings
        installer = WhatsAppGOWAInstaller(settings: settings)
        enabled = settings.enabled
        filters = settings.filters
        installer.onInstalled = { [weak self] in
            guard let self else { return }
            self.gowa.stop()   // an older one gives way
            self.settingsChanged()
        }
    }

    // MARK: ConnectionService

    /// Nothing to set up yet: no gateway installed or typed in.
    private var notSetUp: Bool {
        settings.gateway == .gowa && settings.customURL == nil && !settings.isInstalled
    }

    var pillStatus: ConnectionItem.Status {
        _ = settingsVersion
        guard enabled, !notSetUp else { return .notSetUp }
        switch link {
        case .connected: return .connected
        case .unauthorized, .failed: return .problem
        case .unreachable: return failures >= 2 ? .problem : .notSetUp
        case .off, .connecting, .needsQR: return .notSetUp
        }
    }

    var pillDetail: String {
        let unread = visibleUnread
        return unread > 0 ? "\(unread) unread" : "Messages"
    }

    /// Called once at launch.
    func start() {
        if wakeObserver == nil {
            // Back from sleep: ask the gateway again (after a few seconds, the network comes back first).
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    self?.wake()
                }
            }
        }
        update()
    }

    /// At quit: every timer and task stops, the conversations are forgotten, and GOWA goes if Kobe started it.
    func stop() {
        stop(forget: true)
        gowa.stopNow()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Settings changed or "Refresh": start over with what is saved now.
    func keyChanged() async -> String? {
        settingsChanged()
        return nil
    }

    // MARK: Lifecycle

    /// Settings changed (turned on/off, gateway, URL, credentials, port, binary): start over.
    func settingsChanged() {
        settingsVersion += 1
        stop(forget: !enabled)
        update()
        writeSnapshot()
    }

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        enabled = on
        settingsChanged()
    }

    private func update() {
        // Nothing installed or typed in yet: no polling of a gateway that can't be there.
        if enabled && provider == nil && !notSetUp { begin() }
        else if !enabled && provider != nil { stop(forget: true) }
    }

    private func begin() {
        guard let provider = settings.makeProvider() else {
            link = .failed(WAText.statusBadURL)
            return
        }
        self.provider = provider
        generation += 1
        link = .connecting
        startListener(kind: provider.kind)
        if settings.respectFocus { askFocus() }
        // GOWA started by Kobe when asked to (Settings), before the first check.
        gowa.sync(settings)
        startTicker()
        refresh()
    }

    /// The 5 s tick, without the wake-ups: from the current tick, finds the next one WACadence has work for
    /// (the next tick while not linked, 20 s later once linked) and sleeps straight to it. Re-planned after every
    /// tick, so a link change takes effect at the next due time.
    private func startTicker() {
        ticker?.cancel()
        let gen = generation
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == gen else { return }
                var next = self.tick + 1
                while !self.isDue(next) { next += 1 }
                let wait = Double(next - self.tick) * WACadence.tick
                try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(2))
                guard !Task.isCancelled, self.generation == gen else { return }
                self.tick = next
                self.onTick()
            }
        }
    }

    private func isDue(_ tick: Int) -> Bool {
        let due = WACadence.onTick(tick, linked: link == .connected, failures: failures)
        return due.refresh || due.poll
    }

    /// Stops talking to the gateway. `forget`: the conversations go too.
    private func stop(forget: Bool) {
        generation += 1
        refreshing = false
        polling = false
        ticker?.cancel()
        ticker = nil
        listener.stop()
        provider = nil
        link = .off
        webhook = .off
        qrPNG = nil
        me = nil
        backfilled = false
        lastWebhook = nil
        namingGroups = []
        failures = 0
        // Turned off: GOWA goes too. Otherwise begin() keeps it, or restarts it if its settings changed.
        if !enabled { gowa.stop() }
        if forget {
            openChat = nil
            inbox.clear()
            hasDraft = false
            drafts = [:]
        }
    }

    private func wake() {
        guard provider != nil else { return }
        // Nothing is trusted after a sleep: the gateway may have restarted without Kobe's webhook.
        webhook = webhook == .portBusy ? .portBusy : .listening
        lastWebhook = nil
        refresh()
    }

    private func onTick() {
        let due = WACadence.onTick(tick, linked: link == .connected, failures: failures)
        if due.refresh { refresh() }
        if due.poll { poll() }
    }

    // MARK: Status and QR

    func refresh() {
        guard let provider, !refreshing else { return }
        refreshing = true
        let gen = generation
        Task {
            defer { if gen == generation { refreshing = false } }
            do {
                let status = try await provider.status()
                guard gen == generation else { return }
                failures = 0
                me = status.me
                switch status.link {
                case .connected:
                    if link != .connected { qrPNG = nil }
                    link = .connected
                    if webhook == .listening { await register(provider, gen: gen) }
                    if !backfilled, gen == generation { await backfill(provider, gen: gen) }
                case .needsQR:
                    link = .needsQR
                    if qrPNG == nil || Date() > qrExpiry {
                        // Not asked again for 15 s even when nothing came: each GOWA login call restarts the pairing.
                        qrExpiry = Date().addingTimeInterval(15)
                        if let qr = try await provider.qrCode(), gen == generation {
                            qrPNG = qr.png
                            qrExpiry = Date().addingTimeInterval(TimeInterval(qr.seconds))
                        }
                    }
                case .connecting:
                    link = .connecting
                }
            } catch let error as WAError {
                if gen == generation { apply(error) }
            } catch {
                if gen == generation { apply(.unreachable) }
            }
            if gen == generation { writeSnapshot() }
        }
    }

    private func apply(_ error: WAError) {
        switch error {
        case .unreachable: link = .unreachable
        case .unauthorized: link = .unauthorized
        case .notLoggedIn: link = .needsQR
        case .refused(let why): link = .failed(why)
        }
        guard error != .notLoggedIn else { return }
        failures += 1
        // Twice in a row (not a gateway still starting): the pill's red badge, once.
        if failures == 2, !notSetUp {
            report(ServiceEvent(pill: Self.pill, kind: .error, detail: link.label, sound: .error))
        }
        // GOWA started by Kobe and gone (crash, killed): started again, once a minute at most.
        if error == .unreachable { gowa.sync(settings) }
    }

    /// The chat list as the card shows it: each chat's id (a phone number for a person), name, unread count and a
    /// one-line preview of its last message (100 characters at most); never a full conversation or a credential.
    /// Nothing is written while connecting or briefly unreachable, so the last file stays.
    func writeSnapshot() {
        guard enabled, !notSetUp else { return SnapshotWriter.write(SnapshotBuilders.notSetUp(.whatsapp)) }
        let state: SnapshotBuilders.WALink
        switch link {
        case .off, .connecting: state = .connecting
        case .needsQR: state = .needsQR
        case .connected: state = .linked
        case .unreachable: state = .unreachable
        case .unauthorized, .failed: state = .failed(link.label)
        }
        guard let snapshot = SnapshotBuilders.whatsapp(conversations: visibleConversations, link: state,
                                                       failures: failures, unreachable: Link.unreachable.label)
        else { return }
        SnapshotWriter.write(snapshot)
    }

    /// One check from Settings' "Test connection": what the gateway says, in a sentence.
    func testConnection() async -> String {
        // The running connection when there is one (a second one could race it for OpenWA's session).
        guard let provider = provider ?? settings.makeProvider() else { return WAText.statusBadURL }
        do {
            var status: WAStatus
            var attempt = 0
            while true {
                do {
                    status = try await provider.status()
                    break
                } catch WAError.unreachable where gowa.isRunning && attempt < 8 {
                    // GOWA just started by Kobe: give it a few seconds to come up.
                    attempt += 1
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            switch status.link {
            case .connected: return WAText.testConnected(status.me.map(WAJID.displayNumber) ?? "")
            case .needsQR: return WAText.testNeedsQR
            case .connecting: return WAText.testConnecting
            }
        } catch let error as WAError {
            return error == .notLoggedIn ? WAText.testNeedsQR : error.label
        } catch {
            return WAText.statusUnreachable
        }
    }

    // MARK: Webhook

    private func startListener(kind: WAGatewayKind) {
        let secret = settings.webhookSecret()
        listener.onRequest = { [weak self] request in
            // Signed by the gateway with Kobe's secret, over the exact bytes received.
            let status = WAWebhook.status(for: request, kind: kind, secret: secret)
            if status == 200 {
                let body = request.body
                Task { @MainActor in self?.received(body, kind: kind) }
            }
            return status
        }
        listener.onListening = { [weak self] ok in
            Task { @MainActor in
                guard let self, self.provider != nil else { return }
                if !ok { self.webhook = .portBusy }
                else if self.webhook == .off || self.webhook == .portBusy { self.webhook = .listening; self.refresh() }
            }
        }
        if !listener.start(port: UInt16(settings.port)) { webhook = .portBusy }
    }

    private func register(_ provider: any WhatsAppProvider, gen: Int) async {
        do {
            try await provider.registerWebhook(url: settings.webhookURL, secret: settings.webhookSecret())
            if gen == generation { webhook = .registered }
        } catch WAError.refused(let why) {
            if gen == generation { webhook = .refused(why) }
        } catch {
            // Tried again on the next minute's check.
        }
    }

    private func received(_ body: Data, kind: WAGatewayKind) {
        guard provider != nil else { return }
        lastWebhook = Date()
        if webhook != .registered { webhook = .registered }
        guard case .message(let message)? = WAWebhook.parse(kind: kind, body: body, me: me) else { return }
        ingest([message])
    }

    // MARK: Messages

    /// The last week of chats, once linked: every chat that moved shows in the list with its latest messages; kept,
    /// but nothing counts as new and nothing is announced. Opening one loads the rest.
    private func backfill(_ provider: any WhatsAppProvider, gen: Int) async {
        backfilled = true
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        guard let messages = try? await provider.recentMessages(since: since, me: me), gen == generation else { return }
        for message in messages { inbox.add(message, filters: filters, history: true) }
        for message in messages { nameGroupIfNeeded(message.chat) }
        lastPoll = Date()
    }

    private func poll() {
        guard let provider, !polling, !WACadence.webhookAlive(lastWebhook: lastWebhook), backfilled else { return }
        polling = true
        let since = lastPoll.addingTimeInterval(-30)   // a little overlap; duplicates are dropped
        let started = Date()
        let gen = generation
        Task {
            defer { if gen == generation { polling = false } }
            guard let messages = try? await provider.recentMessages(since: since, me: me), gen == generation else { return }
            lastPoll = started
            ingest(messages)
        }
    }

    private func ingest(_ messages: [WAMessage]) {
        let fresh = inbox.ingest(messages, filters: filters, openChat: openChat)
        for message in messages { nameGroupIfNeeded(message.chat) }
        if let fresh { announce(fresh) }
        writeSnapshot()
    }

    /// Groups arrive under their id (GOWA's webhook carries no group name): asked once.
    private func nameGroupIfNeeded(_ chat: String) {
        let key = WAJID.normalized(chat)
        guard let provider, inbox.needsName(key), !namingGroups.contains(key) else { return }
        namingGroups.insert(key)
        let gen = generation
        Task {
            if let name = await provider.groupName(key), gen == generation { inbox.rename(key, to: name) }
        }
    }

    // MARK: Conversation

    /// A conversation opened on the page: its latest messages from the gateway (the 200 the inbox keeps), and the
    /// read receipt when Settings says so.
    func open(_ chat: String) {
        sendError = nil
        openChat = WAJID.normalized(chat)
        // A reply saved from before is back in the field: it holds the island like one being typed.
        hasDraft = Self.isDraft(drafts[chat] ?? drafts[WAJID.normalized(chat)])
        guard let provider else { return }
        if settings.markReadOnOpen { markRead(chat) }
        let gen = generation
        Task {
            guard let history = try? await provider.messages(chat: chat, limit: WAInbox.keep, me: me), gen == generation else { return }
            for message in history { inbox.add(message, filters: filters, history: true) }
        }
    }

    /// The conversation closed (back to the list, Escape, the card closed).
    func close(_ chat: String) {
        if openChat == WAJID.normalized(chat) { openChat = nil }
        // The field is off screen (the draft, if any, stays saved): nothing holds the island any more.
        hasDraft = false
    }

    /// A draft worth holding the island for: something other than spaces.
    static func isDraft(_ text: String?) -> Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Marks the chat read here and on WhatsApp (up to its newest received message).
    func markRead(_ chat: String) {
        let key = WAJID.normalized(chat)
        guard let provider, let conversation = inbox.conversations[key] else { return }
        inbox.markRead(key)
        writeSnapshot()
        // Nothing new: no receipt to send.
        guard conversation.unread > 0 else { return }
        let last = inbox.lastIncoming(key)
        Task { try? await provider.markRead(chat: key, lastIncoming: last) }
    }

    /// Sends a reply, only from the user's own Return or click in the conversation view. Only to a conversation
    /// already in the inbox, one at a time, a few a minute. True once the gateway took it.
    func send(_ text: String, to chat: String) async -> Bool {
        let key = WAJID.normalized(chat)
        // Each refusal says why; an earlier reason never stays on screen for a new try.
        guard !sending else {
            sendError = WAText.replySending
            return false
        }
        sendError = nil
        if let refusal = WAReply.check(text, to: key, in: inbox) {
            sendError = WAText.refusal(refusal)
            return false
        }
        guard let provider else {
            sendError = WAText.replyNotConnected
            return false
        }
        guard rateLimit.allow() else {
            sendError = WAText.replyTooFast
            return false
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        sendError = nil
        defer { sending = false }
        let gen = generation
        do {
            let id = try await provider.send(text: body, to: key)
            // A "still on its way" said to a second try meanwhile is over now.
            sendError = nil
            // Turned off or restarted meanwhile: the inbox it belonged to is gone.
            guard gen == generation else { return true }
            var mine = WAMessage(id: id ?? "kobe-\(UUID().uuidString)", chat: key, sender: me ?? "",
                                 senderName: "", text: body, date: Date(), fromMe: true)
            mine.chatName = inbox.conversations[key]?.name
            inbox.add(mine, filters: filters)
            // Replying reads the conversation, whatever the setting.
            let last = inbox.lastIncoming(key)
            Task { try? await provider.markRead(chat: key, lastIncoming: last) }
            return true
        } catch let error as WAError {
            sendError = error.label
            return false
        } catch {
            sendError = WAText.statusUnreachable
            return false
        }
    }

    /// WhatsApp's own app (the card's ↗), when it is installed.
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) }

    func openWhatsAppApp() {
        guard let url = Self.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Announcing

    /// A new message reaches you: the pill's badge, the pop sound and the band, with the chat's name only (never
    /// the text). Silent during a Focus; a burst of messages is one announcement.
    private func announce(_ message: WAMessage) {
        if settings.respectFocus && focusIsOn { return }
        // A burst only throttles the sound: the band and badge still follow the newest chat.
        let sound: ServiceEvent.Sound = WACadence.mayAnnounce(last: lastAnnounce) ? .pop : .silent
        if sound == .pop { lastAnnounce = Date() }
        let name = inbox.conversations[WAJID.normalized(message.chat)]?.name ?? WAJID.displayNumber(message.chat)
        report(ServiceEvent(pill: Self.pill, kind: .finished, detail: name, sound: sound))
    }

    // MARK: Focus

    /// macOS Focus, when the system lets Kobe read it.
    private var focusIsOn: Bool {
        guard focusReadable == true else { return false }
        return INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    /// Asks once to read the Focus state. macOS answers only to apps signed with the Communication Notifications
    /// capability; elsewhere this stays unreadable (Settings says so).
    func askFocus() {
        let center = INFocusStatusCenter.default
        switch center.authorizationStatus {
        case .authorized:
            focusReadable = center.focusStatus.isFocused != nil
        case .notDetermined:
            center.requestAuthorization { @Sendable [weak self] status in
                Task { @MainActor in
                    self?.focusReadable = status == .authorized && INFocusStatusCenter.default.focusStatus.isFocused != nil
                }
            }
        default:
            focusReadable = false
        }
    }

    func setRespectFocus(_ on: Bool) {
        settings.respectFocus = on
        settingsVersion += 1
        if on { askFocus() }
    }

    func setMarkReadOnOpen(_ on: Bool) {
        settings.markReadOnOpen = on
        settingsVersion += 1
    }

    // MARK: Filters

    func ignore(_ chat: String) {
        let key = WAJID.normalized(chat)
        filters.ignored.insert(key)
        inbox.remove(key)
        if openChat == key { openChat = nil }
    }

    func unignore(_ chat: String) {
        filters.ignored.remove(chat)
    }
}
