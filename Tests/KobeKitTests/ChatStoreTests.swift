import Foundation
import Synchronization
import Testing
@testable import KobeKit

/// A scripted Hermes: records calls, replays a fixed turn.
final class FakeHermes: HermesAPI, @unchecked Sendable {
    var sessions: [HermesSession] = []
    var created: [String?] = []
    var approvals: [(String, String?, ApprovalChoice)] = []
    var approveError: HermesError?
    var healthErrors: [HermesError] = []
    var turn: [ChatEvent] = [.started(runID: "run_1"), .delta("Hel"), .delta("lo"), .completed(content: "Hello", model: "m1"), .done]
    /// When set, the stream pauses after this many events until `resume()`.
    var pauseAfter: Int?
    /// When set, the stream ends by throwing this after its events (no `.done`).
    var streamError: HermesError?
    /// When set, `stream` itself throws before any event.
    var streamRefused: HermesError?
    /// Messages per chat; chats listed in `slowMessages` wait for `resume()` first.
    var messagesBySession: [String: [HermesMessage]] = [:]
    var slowMessages: Set<String> = []
    /// Pause point shared between the test and the stream task, behind a lock: whichever comes second proceeds.
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func resume() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    private func pause() async {
        await withCheckedContinuation { continuation in
            let go = lock.withLock { () -> Bool in
                if released { return true }
                gate = continuation
                return false
            }
            if go { continuation.resume() }
        }
    }

    func listSessions(limit: Int) async throws -> [HermesSession] { sessions }
    func findSession(title: String) async throws -> HermesSession? { sessions.first { $0.title == title } }
    func createSession(title: String?) async throws -> HermesSession {
        created.append(title)
        let s = HermesSession(id: "api_new", source: "api_server", model: nil, title: title, lastActive: nil, preview: nil, messageCount: 0)
        sessions.insert(s, at: 0)
        return s
    }
    func messages(sessionID: String) async throws -> [HermesMessage] {
        if slowMessages.contains(sessionID) { await pause() }
        return messagesBySession[sessionID]
            ?? [HermesMessage(id: "1", role: "user", content: "Hi", timestamp: 1), HermesMessage(id: "2", role: "assistant", content: "Hello", timestamp: 2)]
    }
    func health() async throws -> HermesHealth {
        if !healthErrors.isEmpty { throw healthErrors.removeFirst() }
        return HermesHealth(reachable: true, version: "0.22.3", platforms: [:])
    }
    var deleted: [String] = []
    var deleteError: HermesError?
    func deleteSession(id: String) async throws {
        deleted.append(id)
        if let deleteError { throw deleteError }
        sessions.removeAll { $0.id == id }
    }
    func approve(runID: String, requestID: String?, choice: ApprovalChoice) async throws {
        approvals.append((runID, requestID, choice))
        if let approveError { throw approveError }
    }
    func stream(sessionID: String, message: String) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        if let streamRefused { throw streamRefused }
        let events = turn
        let pauseAfter = pauseAfter
        let streamError = streamError
        return AsyncThrowingStream { continuation in
            Task {
                for (i, event) in events.enumerated() {
                    if i == pauseAfter { await self.pause() }
                    continuation.yield(event)
                    await Task.yield()
                }
                continuation.finish(throwing: streamError)
            }
        }
    }
}

@MainActor
struct ChatStoreTests {
    @Test func sendCreatesSessionAndStreams() async {
        let api = FakeHermes()
        let store = ChatStore(api: api)
        await store.send("Summarise the brief")
        await store.turn?.value
        #expect(api.created == ["Summarise the brief"])
        #expect(store.lines.map(\.role) == [.user, .kobe])
        #expect(store.lines.last?.text == "Hello")
        #expect(store.model == "m1")
        #expect(!store.isBusy)
    }

    @Test func longFirstMessageGivesA40CharacterTitle() async {
        let api = FakeHermes()
        let store = ChatStore(api: api)
        await store.send(String(repeating: "a", count: 100))
        await store.turn?.value
        #expect(api.created.first??.count == 40)
    }

    @Test func approvalSurfacesAndAnswers() async {
        let api = FakeHermes()
        let request = ApprovalRequest(runID: "run_1", requestID: "r1", command: "touch /tmp/x", description: nil)
        api.turn = [.started(runID: "run_1"), .approval(request), .completed(content: "Done", model: nil), .done]
        api.pauseAfter = 2
        let store = ChatStore(api: api)
        await store.send("Make the file")
        while store.pendingApproval == nil { await Task.yield() }
        #expect(store.pendingApproval == request)
        #expect(store.isBusy)
        await store.answer(.once)
        #expect(api.approvals.count == 1)
        #expect(api.approvals[0].0 == "run_1" && api.approvals[0].1 == "r1" && api.approvals[0].2 == .once)
        #expect(store.pendingApproval == nil)
        api.resume()
        await store.turn?.value
        #expect(!store.isBusy)
    }

    @Test func expiredApprovalClears() async {
        let api = FakeHermes()
        api.approveError = .server(status: 409, code: "approval_not_pending", message: "gone")
        let request = ApprovalRequest(runID: "run_1", requestID: "r1", command: nil, description: "Push")
        api.turn = [.started(runID: "run_1"), .approval(request), .done]
        api.pauseAfter = 2
        let store = ChatStore(api: api)
        await store.send("Push it")
        while store.pendingApproval == nil { await Task.yield() }
        await store.answer(.once)
        #expect(store.approvalNote == "Expired")
        #expect(store.pendingApproval == nil)
        api.resume()
        await store.turn?.value
    }

    @Test func streamSurvivesTheCallerGoingAway() async {
        let api = FakeHermes()
        let store = ChatStore(api: api)
        let caller = Task { await store.send("Hi") }
        await caller.value
        caller.cancel()
        await store.turn?.value
        #expect(store.lastReply == "Hello")
    }

    @Test func quickAskReusesSession() async {
        let api = FakeHermes()
        api.sessions = [HermesSession(id: "qa", source: "api_server", model: nil, title: "Quick ask", lastActive: nil, preview: nil, messageCount: 3)]
        let store = ChatStore(api: api)
        let reply = await store.quickAsk("What's on today?")
        #expect(reply == "Hello")
        #expect(api.created.isEmpty)
        #expect(store.current == nil)  // the open chat is left alone
    }

    @Test func quickAskCreatesItsSessionOnce() async {
        let api = FakeHermes()
        let store = ChatStore(api: api)
        _ = await store.quickAsk("One")
        _ = await store.quickAsk("Two")
        #expect(api.created == ["Quick ask"])
    }

    @Test func quickAskClearsTheApprovalWhenTheStreamEndsWithoutDone() async {
        let api = FakeHermes()
        let request = ApprovalRequest(runID: "run_1", requestID: "r1", command: "x", description: nil)
        api.turn = [.started(runID: "run_1"), .approval(request), .completed(content: "Done", model: nil)]
        let store = ChatStore(api: api)
        _ = await store.quickAsk("Make it")
        #expect(store.pendingApproval == nil)
        #expect(!store.isBusy)
    }

    @Test func quickAskClearsTheApprovalWhenTheStreamFails() async {
        let api = FakeHermes()
        let request = ApprovalRequest(runID: "run_1", requestID: "r1", command: "x", description: nil)
        api.turn = [.started(runID: "run_1"), .approval(request)]
        api.streamError = .offline
        let store = ChatStore(api: api)
        let reply = await store.quickAsk("Make it")
        #expect(reply == "Kobe is offline.")
        #expect(store.pendingApproval == nil)
        #expect(!store.isBusy)
    }

    @Test func openLoadsMessages() async {
        let store = ChatStore(api: FakeHermes())
        await store.open(HermesSession(id: "s", source: "whatsapp", model: nil, title: nil, lastActive: nil, preview: nil, messageCount: 2))
        #expect(store.lines.map(\.text) == ["Hi", "Hello"])
        #expect(store.lines.map(\.role) == [.user, .kobe])
    }

    @Test func reopenedLinesCarryTheirOwnTimes() async {
        let api = FakeHermes()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let t = yesterday.timeIntervalSince1970
        api.messagesBySession["old"] = [HermesMessage(id: "1", role: "user", content: "Hi", timestamp: t),
                                        HermesMessage(id: "2", role: "assistant", content: "Hello", timestamp: t + 5),
                                        HermesMessage(id: "3", role: "assistant", content: "No time", timestamp: nil)]
        let store = ChatStore(api: api)
        await store.open(HermesSession(id: "old", source: "api_server", model: nil, title: nil, lastActive: nil, preview: nil, messageCount: 3))
        let cal = Calendar.current
        #expect(abs(store.lines[0].at.timeIntervalSince1970 - t) < 0.001)
        let first = ChatTimeline.dividers(Array(store.lines.prefix(2)), calendar: cal)
        #expect(first == [store.lines[0].id])
        #expect(ChatTimeline.label(store.lines[0].at, now: .now, calendar: cal) == "Yesterday")
        #expect(cal.isDate(store.lines[2].at, inSameDayAs: .now))
    }

    @Test func failedTurnShowsANotice() async {
        let api = FakeHermes()
        api.turn = [.started(runID: "r"), .failed("boom"), .done]
        let store = ChatStore(api: api)
        await store.send("Hi")
        await store.turn?.value
        #expect(store.lines.last?.role == .notice)
        #expect(store.lines.last?.text == "boom")
        #expect(!store.isBusy)
    }
}

@MainActor
struct ChatPolishTests {
    @Test func statusFollowsToolEvents() async {
        let api = FakeHermes()
        api.turn = [.started(runID: "r"), .tool(name: "web_search", phase: .started, preview: nil),
                    .tool(name: "web_search", phase: .completed, preview: nil),
                    .tool(name: "memory_read", phase: .started, preview: nil),
                    .tool(name: "web_search", phase: .started, preview: nil),
                    .completed(content: "Done", model: nil), .done]
        api.pauseAfter = 2
        let store = ChatStore(api: api)
        await store.send("Look it up")
        while store.status == nil { await Task.yield() }
        #expect(store.status == "searching the web…")
        #expect(store.lines.allSatisfy { $0.role != .tool })
        api.resume()
        await store.turn?.value
        #expect(store.status == nil)
        #expect(store.toolsUsed == ["web search", "memory"])
        #expect(store.lines.last?.role == .tool)
        #expect(store.lines.last?.text == "Used: web search, memory")
        #expect(store.lastTurnEnded == .completed)
    }

    @Test func thinkingStatus() async {
        let api = FakeHermes()
        api.turn = [.started(runID: "r"), .tool(name: "", phase: .thinking, preview: nil), .completed(content: "Ok", model: nil), .done]
        api.pauseAfter = 2
        let store = ChatStore(api: api)
        await store.send("Hmm")
        while store.status == nil { await Task.yield() }
        #expect(store.status == ToolWording.thinking)
        api.resume()
        await store.turn?.value
        #expect(store.status == nil)
        #expect(store.lines.allSatisfy { $0.role != .tool })
    }

    @Test func stopKeepsThePartialReply() async {
        let api = FakeHermes()
        api.turn = [.started(runID: "r"), .delta("Par"), .delta("tial"), .done]
        api.pauseAfter = 3
        let store = ChatStore(api: api)
        await store.send("Go")
        while store.lines.last?.text != "Partial" { await Task.yield() }
        store.stop()
        api.resume()
        await store.turn?.value
        #expect(store.lines.map(\.role) == [.user, .kobe, .notice])
        #expect(store.lines[1].text == "Partial")
        #expect(store.lines[2].text == "(stopped)")
        #expect(store.lastTurnEnded == .stopped)
        #expect(!store.isBusy)
    }

    @Test func stopWithNothingShowsStopped() async {
        let api = FakeHermes()
        api.turn = [.started(runID: "r"), .cancelled, .done]
        let store = ChatStore(api: api)
        await store.send("Go")
        await store.turn?.value
        #expect(store.lines.map(\.role) == [.user, .notice])
        #expect(store.lines.last?.text == "Stopped.")
        #expect(store.lastTurnEnded == .stopped)
    }

    @Test func cancelledEventKeepsPartialText() async {
        let api = FakeHermes()
        api.turn = [.started(runID: "r"), .delta("Half"), .cancelled, .done]
        let store = ChatStore(api: api)
        await store.send("Go")
        await store.turn?.value
        #expect(store.lines.map(\.text) == ["Go", "Half", "(stopped)"])
        #expect(store.lastTurnEnded == .stopped)
    }

    @Test func retryKeepsOneUserLine() async {
        let api = FakeHermes()
        api.turn = [.started(runID: "r"), .delta("Par"), .failed("boom"), .done]
        let store = ChatStore(api: api)
        await store.send("Question")
        await store.turn?.value
        #expect(store.lastTurnEnded == .failed)
        #expect(store.lastUserLine?.text == "Question")
        api.turn = [.started(runID: "r2"), .completed(content: "Answer", model: nil), .done]
        #expect(await store.retry())
        await store.turn?.value
        #expect(store.lines.filter { $0.role == .user }.count == 1)
        #expect(store.lines.filter { $0.role == .kobe }.count == 1)
        #expect(store.lines.map(\.role) == [.user, .kobe])
        #expect(store.lines.last?.text == "Answer")
        #expect(api.created == ["Question"])
        #expect(store.lastTurnEnded == .completed)
    }

    @Test func retryAfterStopRestreams() async {
        let api = FakeHermes()
        api.turn = [.started(runID: "r"), .delta("Half"), .cancelled, .done]
        let store = ChatStore(api: api)
        await store.send("Q")
        await store.turn?.value
        api.turn = [.started(runID: "r2"), .completed(content: "Full", model: nil), .done]
        #expect(await store.retry())
        await store.turn?.value
        #expect(store.lines.map(\.text) == ["Q", "Full"])
    }

    @Test func retryRefusedWhileBusyOrAfterSuccess() async {
        let api = FakeHermes()
        let store = ChatStore(api: api)
        #expect(await store.retry() == false)
        api.pauseAfter = 1
        await store.send("Hi")
        #expect(store.lastTurnEnded == nil)
        #expect(await store.retry() == false)
        api.resume()
        await store.turn?.value
        #expect(store.lastTurnEnded == .completed)
        #expect(await store.retry() == false)
        #expect(store.lines.map(\.role) == [.user, .kobe])
    }

    @Test func linesCarryATime() async {
        let before = Date.now
        let store = ChatStore(api: FakeHermes())
        await store.send("Hi")
        await store.turn?.value
        #expect(store.lines.count == 2)
        #expect(store.lines.allSatisfy { $0.at >= before && $0.at <= Date.now })
        #expect(ChatLine(role: .user, text: "x", at: Date(timeIntervalSince1970: 5)).at == Date(timeIntervalSince1970: 5))
    }
}

@MainActor
struct ReviewFixTests {
    @Test func sendWhileBusyIsRefused() async {
        let api = FakeHermes()
        api.pauseAfter = 1
        let store = ChatStore(api: api)
        #expect(await store.send("First"))
        #expect(await store.send("Second") == false)
        #expect(store.lines.filter { $0.role == .user }.map(\.text) == ["First"])
        api.resume()
        await store.turn?.value
    }

    @Test func aSendWhoseStreamIsRefusedLeavesNoEmptyBubbleAndReturnsFalse() async {
        let api = FakeHermes()
        api.streamRefused = .offline
        let store = ChatStore(api: api)
        #expect(await store.send("Hi") == false)
        // Only the notice stays: the draft goes back into the composer, so the message must not look sent.
        #expect(store.lines.map(\.role) == [.notice])
        #expect(store.lines.first?.text == "Kobe is offline.")
        #expect(!store.isBusy)
        #expect(store.lastError == .offline)
    }

    @Test func openQuickAskOpensItsSession() async {
        let api = FakeHermes()
        let store = ChatStore(api: api)
        _ = await store.quickAsk("One")
        await store.openQuickAsk()
        #expect(store.current?.title == "Quick ask")
    }

    @Test func answeringTwiceSendsOnce() async {
        let api = FakeHermes()
        let request = ApprovalRequest(runID: "run_1", requestID: "r1", command: "x", description: nil)
        api.turn = [.started(runID: "run_1"), .approval(request), .done]
        api.pauseAfter = 2
        let store = ChatStore(api: api)
        await store.send("Go")
        while store.pendingApproval == nil { await Task.yield() }
        async let first: Void = store.answer(.once)
        async let second: Void = store.answer(.once)
        _ = await (first, second)
        #expect(api.approvals.count == 1)
        #expect(store.approvalNote == nil)
        api.resume()
        await store.turn?.value
    }
}

@MainActor
struct ForeignChatTests {
    let whatsapp = HermesSession(id: "wa1", source: "whatsapp", model: nil, title: "Interview", lastActive: nil, preview: nil, messageCount: 4)

    @Test func onlyNotchChatsTakeMessagesFromKobe() {
        #expect(!whatsapp.acceptsMessagesFromNotch)
        #expect(HermesSession(id: "a", source: "api_server", model: nil, title: nil, lastActive: nil, preview: nil, messageCount: nil).acceptsMessagesFromNotch)
        #expect(HermesSession(id: "b", source: nil, model: nil, title: nil, lastActive: nil, preview: nil, messageCount: nil).acceptsMessagesFromNotch)
    }

    @Test func writingInAWhatsAppChatStartsANewNotchChat() async {
        let api = FakeHermes()
        api.sessions = [whatsapp]
        let store = ChatStore(api: api)
        await store.open(whatsapp)
        #expect(await store.send("Kobe"))
        await store.turn?.value
        #expect(api.created == ["Kobe"])
        #expect(store.current?.id == "api_new")
        #expect(store.lines.first?.role == .notice)
        #expect(store.lines.first?.text == "WhatsApp chats can only be continued in WhatsApp, so this is a new chat.")
        #expect(store.lines.last?.text == "Hello")
    }

    @Test func aRefusedTurnSaysWhyInWords() async {
        let api = FakeHermes()
        api.turn = [.started(runID: "r"), .failed("permission_denied"), .done]
        let store = ChatStore(api: api)
        await store.send("Hi")
        await store.turn?.value
        #expect(store.lines.last?.text == "Kobe can't add to this chat from here. Start a new chat instead.")
    }
}

@MainActor
struct RaceTests {
    let a = HermesSession(id: "a", source: "api_server", model: nil, title: "A", lastActive: nil, preview: nil, messageCount: 1)
    let b = HermesSession(id: "b", source: "api_server", model: nil, title: "B", lastActive: nil, preview: nil, messageCount: 1)

    func api() -> FakeHermes {
        let api = FakeHermes()
        api.messagesBySession = ["a": [HermesMessage(id: "1", role: "user", content: "from A", timestamp: 1)],
                                 "b": [HermesMessage(id: "2", role: "user", content: "from B", timestamp: 1)]]
        return api
    }

    @Test func aSlowerEarlierOpenNeverOverwritesTheLaterOne() async {
        let api = api()
        api.slowMessages = ["a"]
        let store = ChatStore(api: api)
        let first = Task { await store.open(a) }
        await Task.yield()
        await store.open(b)
        #expect(store.current?.id == "b")
        api.resume()
        await first.value
        #expect(store.current?.id == "b")
        #expect(store.lines.map(\.text) == ["from B"])
    }

    @Test func openingAnotherChatDuringATurnStopsItAndKeepsItsLinesOut() async {
        let api = api()
        api.pauseAfter = 1
        let store = ChatStore(api: api)
        await store.send("Hi")
        #expect(store.isBusy)
        await store.open(b)
        #expect(!store.isBusy)
        #expect(store.lines.map(\.text) == ["from B"])
        api.resume()
        await store.turn?.value
        #expect(store.lines.map(\.text) == ["from B"])
        #expect(store.pendingApproval == nil)
    }

    @Test func deletingTheOpenChatDuringATurnStopsTheTurnFirst() async {
        let api = api()
        api.pauseAfter = 1
        let store = ChatStore(api: api)
        await store.send("Hi")
        let chat = store.current!
        await store.delete(chat)
        #expect(api.deleted == [chat.id])
        #expect(!store.isBusy)
        #expect(store.current == nil && store.lines.isEmpty)
        api.resume()
        await store.turn?.value
        #expect(store.lines.isEmpty)
    }

    @Test func aRefusedDeleteOfTheOpenChatSaysWhy() async {
        let api = api()
        api.deleteError = .server(status: 409, code: "session_active_turn", message: "Session has an active turn")
        let store = ChatStore(api: api)
        await store.open(a)
        await store.delete(a)
        #expect(store.current?.id == "a")
        #expect(store.lastError == api.deleteError)
        #expect(store.lines.last?.role == .notice)
        #expect(store.lines.last?.text == "Kobe is still answering in this chat. Try again in a moment.")
    }
}

@MainActor
struct DeleteTests {
    @Test func deleteRemovesTheChatAndClosesItIfOpen() async {
        let api = FakeHermes()
        let chat = HermesSession(id: "s1", source: "api_server", model: nil, title: "Old", lastActive: nil, preview: nil, messageCount: 2)
        api.sessions = [chat]
        let store = ChatStore(api: api)
        await store.refreshSessions()
        await store.open(chat)
        await store.delete(chat)
        #expect(api.deleted == ["s1"])
        #expect(store.sessions.isEmpty)
        #expect(store.current == nil && store.lines.isEmpty)
    }
}

@MainActor
struct ConnectionTests {
    @Test func aFailureAfterConnectingStartsRetrying() async {
        let api = FakeHermes()
        let sleeps = Mutex<[Int]>([])
        let connection = Connection(api: api, keyIsSet: { true }, sleep: { s in sleeps.withLock { $0.append(s) } })
        await connection.check()
        #expect(connection.isConnected)
        api.healthErrors = [.offline, .offline]
        await connection.noteFailure(.offline)
        #expect(sleeps.withLock { $0 } == [1, 2])
        #expect(connection.isConnected)
    }

    @Test func aRefusedKeyAfterConnectingShows() async {
        let api = FakeHermes()
        let connection = Connection(api: api, keyIsSet: { true }, sleep: { _ in })
        await connection.check()
        await connection.noteFailure(.unauthorized)
        #expect(connection.state == .unauthorized)
    }

    @Test func offlineBackoffSequence() async {
        let api = FakeHermes()
        api.healthErrors = Array(repeating: .offline, count: 9)
        let sleeps = Mutex<[Int]>([])
        let connection = Connection(api: api, keyIsSet: { true }, sleep: { seconds in sleeps.withLock { $0.append(seconds) } })
        await connection.check()
        #expect(sleeps.withLock { $0 } == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        #expect(connection.state == .connected(version: "0.22.3"))
    }

    @Test func noKeyDoesNotRetry() async {
        let sleeps = Mutex<[Int]>([])
        let connection = Connection(api: FakeHermes(), keyIsSet: { false }, sleep: { s in sleeps.withLock { $0.append(s) } })
        await connection.check()
        #expect(connection.state == .noKey)
        #expect(sleeps.withLock { $0 }.isEmpty)
    }

    @Test func unauthorizedDoesNotRetry() async {
        let api = FakeHermes()
        api.healthErrors = [.unauthorized]
        let sleeps = Mutex<[Int]>([])
        let connection = Connection(api: api, keyIsSet: { true }, sleep: { s in sleeps.withLock { $0.append(s) } })
        await connection.check()
        #expect(connection.state == .unauthorized)
        #expect(sleeps.withLock { $0 }.isEmpty)
    }
}
