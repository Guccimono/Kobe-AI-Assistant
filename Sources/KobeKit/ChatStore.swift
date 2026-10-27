import Foundation
import Observation

/// What the chat store needs from Hermes. `HermesClient` is the live one; tests use a fake.
public protocol HermesAPI: Sendable {
    func listSessions(limit: Int) async throws -> [HermesSession]
    func findSession(title: String) async throws -> HermesSession?
    func createSession(title: String?) async throws -> HermesSession
    func createSession(title: String?, systemPrompt: String?) async throws -> HermesSession
    func messages(sessionID: String) async throws -> [HermesMessage]
    func health() async throws -> HermesHealth
    func approve(runID: String, requestID: String?, choice: ApprovalChoice) async throws
    func deleteSession(id: String) async throws
    func stream(sessionID: String, message: String) async throws -> AsyncThrowingStream<ChatEvent, Error>
}

extension HermesAPI {
    /// For APIs that don't take a system prompt: the session is made without it.
    public func createSession(title: String?, systemPrompt: String?) async throws -> HermesSession {
        try await createSession(title: title)
    }
}

extension HermesClient: HermesAPI {
    public func stream(sessionID: String, message: String) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        chatEvents(for: try streamRequest(sessionID: sessionID, message: message), session: session, copy: copy)
    }
}

public struct ChatLine: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, kobe, tool, notice }
    public let id: UUID
    public var role: Role
    public var text: String
    /// When the line was made (the time a chat shows under a bubble).
    public var at: Date

    public init(id: UUID = UUID(), role: Role, text: String, at: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
    }
}

/// How the last turn ended; nil while one is running and before any.
public enum TurnEnd: Equatable, Sendable { case completed, failed, stopped }

/// The chats with Kobe: the list, the open one, the turn in progress and its approval. The turn's task belongs to the
/// store, never to a view: Hermes interrupts a turn when its stream disconnects, so closing the notch must not cancel it.
@MainActor
@Observable
public final class ChatStore {
    public private(set) var sessions: [HermesSession] = []
    public private(set) var current: HermesSession?
    public private(set) var lines: [ChatLine] = []
    public private(set) var isBusy = false
    public private(set) var pendingApproval: ApprovalRequest?
    /// A short note about the last approval ("Expired"), cleared on the next one.
    public private(set) var approvalNote: String?
    public private(set) var model: String?
    public private(set) var lastReply: String?
    public private(set) var lastError: HermesError?
    /// The assistant's name in the notices and errors; the app keeps it in step with the setting.
    public var copy = Copy(name: "Kobe")
    /// What Kobe is doing right now ("searching the web…"); nil when idle.
    public private(set) var status: String?
    /// The tools the turn used, in plain words, once each, in order.
    public private(set) var toolsUsed: [String] = []
    public private(set) var lastTurnEnded: TurnEnd?
    /// The last message the user sent in the open chat.
    public var lastUserLine: ChatLine? { lines.last { $0.role == .user } }
    /// The turn in progress, if any.
    public private(set) var turn: Task<Void, Never>?

    @ObservationIgnored private let api: any HermesAPI
    @ObservationIgnored private var quickAskSession: HermesSession?
    /// Bumped by every `open`: a slower, earlier load must not land under a chat opened later.
    @ObservationIgnored private var openGeneration = 0
    /// Bumped when a turn is ended from outside (open or delete during it): the orphaned stream touches nothing.
    @ObservationIgnored private var turnGeneration = 0

    /// The system prompt a new chat is created with (nil: none). The app answers with the assistant's profile when
    /// the engine's SOUL.md doesn't already carry it.
    @ObservationIgnored private let systemPrompt: @MainActor () -> String?

    public init(api: any HermesAPI, systemPrompt: @escaping @MainActor () -> String? = { nil }) {
        self.api = api
        self.systemPrompt = systemPrompt
    }

    public func refreshSessions() async {
        do {
            sessions = try await api.listSessions(limit: 50)
            lastError = nil
        } catch {
            lastError = error as? HermesError
        }
    }

    /// Opens a chat. During a turn, opening another chat stops the turn first (the chat being answered stays as it is).
    public func open(_ session: HermesSession) async {
        if isBusy {
            guard current?.id != session.id else { return }
            endTurn()
        }
        openGeneration += 1
        let generation = openGeneration
        lastTurnEnded = nil
        current = session
        let loaded: [ChatLine]
        do {
            loaded = try await api.messages(sessionID: session.id).compactMap { message -> ChatLine? in
                // Hermes stamps messages in seconds since 1970; a message without a stamp reads as now.
                let at = message.timestamp.map { Date(timeIntervalSince1970: $0) } ?? .now
                switch message.role {
                case "user": return ChatLine(role: .user, text: message.content, at: at)
                case "assistant": return ChatLine(role: .kobe, text: message.content, at: at)
                default: return nil
                }
            }
        } catch {
            guard generation == openGeneration else { return }
            lines = [ChatLine(role: .notice, text: "Couldn't load this chat.")]
            lastError = error as? HermesError
            return
        }
        guard generation == openGeneration else { return }
        lines = loaded
    }

    /// Deletes a chat in Hermes; an open chat closes, and a turn running in it is stopped first. When Hermes refuses
    /// (409 while its turn is still winding down), the open chat says so.
    public func delete(_ session: HermesSession) async {
        if isBusy, current?.id == session.id { endTurn() }
        do {
            try await api.deleteSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
            if current?.id == session.id { newChat() }
            if quickAskSession?.id == session.id { quickAskSession = nil }
        } catch {
            lastError = error as? HermesError
            if current?.id == session.id { lines.append(ChatLine(role: .notice, text: Self.describe(error, copy: copy))) }
        }
    }

    public func newChat() {
        lastTurnEnded = nil
        current = nil
        lines = []
    }

    /// Sends a message in the open chat (creating one titled from the message if none is open). Returns once the
    /// turn has started; `turn` finishes when Kobe is done.
    @discardableResult
    public func send(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return false }
        isBusy = true
        if let current, !current.acceptsMessagesFromNotch {
            // Hermes refuses API turns in chats another surface owns: carry on in a new notch chat.
            let place = current.sourceLabel(copy: copy)
            newChat()
            lines.append(ChatLine(role: .notice, text: "\(place) chats can only be continued in \(place), so this is a new chat."))
        }
        let userID = UUID()
        lines.append(ChatLine(id: userID, role: .user, text: text))
        return await stream(text: text, userID: userID)
    }

    /// Sends the last message again after a failed or stopped turn: the partial reply and the notices after it go,
    /// and the same text streams on the current chat without a second user line.
    @discardableResult
    public func retry() async -> Bool {
        guard !isBusy, lastTurnEnded == .failed || lastTurnEnded == .stopped,
              let index = lines.lastIndex(where: { $0.role == .user }) else { return false }
        let text = lines[index].text
        isBusy = true
        lines.removeSubrange((index + 1)...)
        return await stream(text: text, userID: nil)
    }

    /// Starts the turn for `text`. `userID` is the user line a fresh send just added (taken back if nothing was sent);
    /// a retry passes nil and keeps its line.
    private func stream(text: String, userID: UUID?) async -> Bool {
        let replyID = UUID()
        lastTurnEnded = nil
        status = nil
        toolsUsed = []
        do {
            let session: HermesSession
            if let current {
                session = current
            } else {
                session = try await api.createSession(title: String(text.prefix(40)), systemPrompt: systemPrompt())
                current = session
            }
            lines.append(ChatLine(id: replyID, role: .kobe, text: ""))
            let events = try await api.stream(sessionID: session.id, message: text)
            let generation = turnGeneration
            turn = Task { [weak self] in
                await self?.consume(events, replyID: replyID, generation: generation)
            }
        } catch {
            // A send put nothing through: the message goes back into the composer (false), so it must not look sent here.
            lines.removeAll { $0.id == userID || $0.id == replyID }
            fail(error)
            if userID == nil { lastTurnEnded = .failed }
            return false
        }
        return true
    }

    /// Opens the "Quick ask" chat in the chat view.
    public func openQuickAsk() async {
        if quickAskSession == nil { quickAskSession = try? await api.findSession(title: ChatTitles.quickAsk) }
        if let session = quickAskSession { await open(session) }
    }

    /// One question in the "Quick ask" chat, without touching the open chat. Returns Kobe's answer.
    public func quickAsk(_ text: String) async -> String {
        guard !isBusy else { return "\(copy.name) is busy with another answer." }
        isBusy = true
        // Whatever way the stream ends (done, no done, an error), no approval of this turn is left to answer.
        defer { isBusy = false; pendingApproval = nil }
        do {
            let session: HermesSession
            if let known = quickAskSession {
                session = known
            } else if let found = try await api.findSession(title: ChatTitles.quickAsk) {
                session = found
            } else {
                session = try await api.createSession(title: ChatTitles.quickAsk, systemPrompt: systemPrompt())
            }
            quickAskSession = session
            var reply = ""
            for try await event in try await api.stream(sessionID: session.id, message: text) {
                switch event {
                case .delta(let piece): reply += piece
                case .completed(let content, let model):
                    reply = content
                    if let model { self.model = model }
                case .approval(let request): pendingApproval = request; approvalNote = nil
                case .failed(let message): reply = message
                case .done: pendingApproval = nil
                default: break
                }
            }
            lastReply = reply
            return reply
        } catch {
            lastError = error as? HermesError
            return Self.describe(error, copy: copy)
        }
    }

    public func answer(_ choice: ApprovalChoice) async {
        guard let request = pendingApproval else { return }
        // Cleared before the call, so a second click can't answer the same request twice.
        pendingApproval = nil
        do {
            try await api.approve(runID: request.runID, requestID: request.requestID, choice: choice)
            approvalNote = nil
        } catch HermesError.server(409, "approval_not_pending", _) {
            pendingApproval = nil
            approvalNote = "Expired"
        } catch {
            pendingApproval = request
            approvalNote = Self.describe(error, copy: copy)
        }
    }

    /// The only way to cancel a turn: Hermes interrupts it when the stream closes.
    public func stop() {
        turn?.cancel()
    }

    /// Ends the turn in progress on the store's side as well: the stream is cancelled and whatever it still yields
    /// is dropped, so a chat opened next never receives its lines.
    private func endTurn() {
        stop()
        turnGeneration += 1
        isBusy = false
        pendingApproval = nil
        status = nil
        lastTurnEnded = nil
    }

    private func consume(_ events: AsyncThrowingStream<ChatEvent, Error>, replyID: UUID, generation: Int) async {
        var end = TurnEnd.completed
        do {
            for try await event in events {
                guard generation == turnGeneration else { return }
                switch event {
                case .started:
                    break
                case .delta(let piece):
                    update(replyID) { $0 += piece }
                case .tool(let name, let phase, _):
                    switch phase {
                    case .started:
                        status = ToolWording.phrase(name: name)
                        let short = ToolWording.short(name: name)
                        if !toolsUsed.contains(short) { toolsUsed.append(short) }
                    case .thinking:
                        status = ToolWording.thinking
                    case .completed, .failed:
                        status = nil
                    }
                case .approval(let request):
                    pendingApproval = request
                    approvalNote = nil
                case .completed(let content, let model):
                    update(replyID) { $0 = content }
                    lastReply = content
                    status = nil
                    if let model { self.model = model }
                case .failed(let message):
                    status = nil
                    end = .failed
                    lines.append(ChatLine(role: .notice, text: Self.readable(message, copy: copy)))
                case .cancelled:
                    status = nil
                    end = .stopped
                    stoppedNotice(replyID)
                case .done:
                    break
                }
            }
        } catch {
            guard generation == turnGeneration else { return }
            if Task.isCancelled {
                end = .stopped
            } else {
                end = .failed
                lines.append(ChatLine(role: .notice, text: Self.describe(error, copy: copy)))
            }
            lastError = error as? HermesError
        }
        guard generation == turnGeneration else { return }
        if Task.isCancelled, end == .completed {
            end = .stopped
            stoppedNotice(replyID)
        }
        lines.removeAll { $0.id == replyID && $0.text.isEmpty }
        if !toolsUsed.isEmpty { lines.append(ChatLine(role: .tool, text: "Used: " + toolsUsed.joined(separator: ", "))) }
        status = nil
        pendingApproval = nil
        lastTurnEnded = end
        isBusy = false
        await refreshSessions()
    }

    /// A stopped turn keeps what Kobe had said, marked "(stopped)"; with nothing said, "Stopped." stands alone.
    private func stoppedNotice(_ replyID: UUID) {
        let said = lines.first { $0.id == replyID }.map { !$0.text.isEmpty } ?? false
        if said, let index = lines.firstIndex(where: { $0.id == replyID }) {
            lines.insert(ChatLine(role: .notice, text: "(stopped)"), at: index + 1)
        } else {
            lines.removeAll { $0.id == replyID }
            lines.append(ChatLine(role: .notice, text: "Stopped."))
        }
    }

    private func update(_ id: UUID, _ change: (inout String) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[index].text)
    }

    private func fail(_ error: Error) {
        lastError = error as? HermesError
        lines.append(ChatLine(role: .notice, text: Self.describe(error, copy: copy)))
        isBusy = false
    }

    /// Hermes' error codes in words.
    static func readable(_ message: String, copy: Copy = Copy(name: "Kobe")) -> String {
        switch message {
        case "permission_denied": "\(copy.name) can't add to this chat from here. Start a new chat instead."
        case "session_active_turn": "\(copy.name) is still answering in this chat. Try again in a moment."
        default: message
        }
    }

    public static func describe(_ error: Error, copy: Copy = Copy(name: "Kobe")) -> String {
        switch error as? HermesError {
        case .noKey: "Connect to \(copy.name) in Settings first."
        case .unauthorized: "\(copy.name) refused the key. Check it in Settings."
        case .offline: "\(copy.name) is offline."
        case .notFound: "That chat no longer exists."
        case .server(_, let code, let message): code.map { readable($0, copy: copy) }.flatMap { $0 == code ? nil : $0 } ?? message
        case nil: error.localizedDescription
        }
    }
}
