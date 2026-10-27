import Foundation
import Testing
import Synchronization
@testable import KobeKit

private func client(key: String? = "test-key", _ handler: @escaping StubURLProtocol.Handler) -> (HermesClient, String) {
    let stub = StubURLProtocol.make(handler)
    return (HermesClient(baseURL: stub.base, key: { key }, session: stub.session), stub.host)
}

@Test func listsSessionsWithLabels() async throws {
    let (api, _) = client { _ in .init(body: StubURLProtocol.fixture("sessions.json")) }
    let sessions = try await api.listSessions()
    #expect(sessions.map(\.sourceLabel) == ["Notch", "WhatsApp"])
    #expect(sessions[0].id == "api_1792600000_ab12cd34")
    #expect(sessions[0].lastActive == 1792600100.0)
}

@Test func quickAskTitleLabelsAsQuickAsk() {
    let s = HermesSession(id: "x", source: "api_server", model: nil, title: "Quick ask", lastActive: nil, preview: nil, messageCount: nil)
    #expect(s.sourceLabel == "Quick ask")
}

@Test func readsTheBaseURLOnEveryRequest() async throws {
    let a = StubURLProtocol.make { _ in .init(body: StubURLProtocol.fixture("sessions.json")) }
    let b = StubURLProtocol.make { _ in .init(body: StubURLProtocol.fixture("sessions.json")) }
    let current = Mutex(a.base)
    let api = HermesClient(baseURL: { current.withLock { $0 } }, key: { "k" }, session: a.session)
    _ = try await api.listSessions()
    current.withLock { $0 = b.base }
    _ = try await api.listSessions()
    #expect(StubURLProtocol.requests(a.host).count == 1)
    #expect(StubURLProtocol.requests(b.host).count == 1)
    #expect(api.baseURL == b.base)
}

@Test func sendsBearerKey() async throws {
    let (api, host) = client { _ in .init(body: StubURLProtocol.fixture("sessions.json")) }
    _ = try await api.listSessions()
    #expect(StubURLProtocol.requests(host).first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
}

@Test func noKeyThrowsBeforeNetwork() async {
    let (api, host) = client(key: nil) { _ in .init() }
    await #expect(throws: HermesError.noKey) { try await api.listSessions() }
    #expect(StubURLProtocol.requests(host).isEmpty)
}

@Test func unauthorizedMaps() async {
    let (api, _) = client { _ in .init(status: 401, body: StubURLProtocol.fixture("error_401.json")) }
    await #expect(throws: HermesError.unauthorized) { try await api.listSessions() }
}

@Test func connectionRefusedIsOffline() async {
    let (api, _) = client { _ in .init(error: URLError(.cannotConnectToHost)) }
    await #expect(throws: HermesError.offline) { try await api.health() }
}

@Test func messagesSkipHiddenAndOrderOldestFirst() async throws {
    let (api, host) = client { _ in .init(body: StubURLProtocol.fixture("messages.json")) }
    let messages = try await api.messages(sessionID: "api_1")
    #expect(messages.map(\.content) == ["Say hi", "Hello Sam"])
    #expect(messages.map(\.id) == ["11", "12"])
    let url = StubURLProtocol.requests(host).first?.url?.absoluteString ?? ""
    #expect(url.contains("/api/sessions/api_1/messages") && url.contains("order=latest"))
}

@Test func healthReadsPlatformStates() async throws {
    let (api, _) = client { _ in .init(body: StubURLProtocol.fixture("health_detailed.json")) }
    let health = try await api.health()
    #expect(health.reachable && health.version == "0.22.3")
    #expect(health.platforms["whatsapp"] == false)
    #expect(health.platforms["api_server"] == true)
}

@Test func createSessionSendsTitleAndSource() async throws {
    let (api, host) = client { _ in
        .init(status: 201, body: Data(#"{"id":"api_9","source":"api_server","title":"Hello there"}"#.utf8))
    }
    let created = try await api.createSession(title: "Hello there")
    #expect(created.id == "api_9")
    let request = StubURLProtocol.requests(host)[0]
    #expect(request.httpMethod == "POST")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
    #expect(body == ["title": "Hello there", "source": "api_server"])
}

@Test func createSessionSendsTheSystemPromptAndReadsItBack() async throws {
    let (api, host) = client { _ in
        .init(status: 201, body: Data(#"{"id":"api_11","source":"api_server","title":"Kobe","has_system_prompt":true}"#.utf8))
    }
    let created = try await api.createSession(title: "Kobe", systemPrompt: "You are Kobe.")
    #expect(created.hasSystemPrompt == true)
    let body = try JSONSerialization.jsonObject(with: StubURLProtocol.requests(host)[0].httpBody!) as! [String: String]
    #expect(body == ["title": "Kobe", "source": "api_server", "system_prompt": "You are Kobe."])
}

@Test func createSessionReadsTheWrappedSession() async throws {
    let (api, _) = client { _ in
        .init(status: 201, body: Data(#"{"object":"hermes.session","session":{"id":"api_10","source":"api_server","title":null}}"#.utf8))
    }
    let created = try await api.createSession(title: nil)
    #expect(created.id == "api_10")
    #expect(created.source == "api_server")
}

@Test func approveSendsChoiceAndRequestID() async throws {
    let (api, host) = client { _ in .init(body: Data(#"{"object":"hermes.run.approval_response","resolved":1}"#.utf8)) }
    try await api.approve(runID: "run_1", requestID: "r1", choice: .once)
    let request = StubURLProtocol.requests(host)[0]
    #expect(request.url?.path == "/v1/runs/run_1/approval")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
    #expect(body == ["choice": "once", "request_id": "r1"])
}

@Test func expiredApprovalIs409() async {
    let (api, _) = client { _ in
        .init(status: 409, body: Data(#"{"error":{"message":"Run has no pending approval: run_1","code":"approval_not_pending"}}"#.utf8))
    }
    await #expect(throws: HermesError.server(status: 409, code: "approval_not_pending", message: "Run has no pending approval: run_1")) {
        try await api.approve(runID: "run_1", requestID: nil, choice: .deny)
    }
}

@Test func deleteSessionSendsDelete() async throws {
    let (api, host) = client { _ in .init(body: Data(#"{"deleted":true}"#.utf8)) }
    try await api.deleteSession(id: "api_1")
    let request = StubURLProtocol.requests(host)[0]
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.path == "/api/sessions/api_1")
}

@Test func sessionsCarryUsage() async throws {
    let (api, _) = client { _ in
        .init(body: Data(#"{"data":[{"id":"a","source":"whatsapp","started_at":100.0,"message_count":4,"tool_call_count":2,"input_tokens":300,"output_tokens":120}]}"#.utf8))
    }
    let s = try await api.listSessions()[0]
    #expect(s.startedAt == 100 && s.toolCallCount == 2 && s.inputTokens == 300 && s.outputTokens == 120)
}

// MARK: Cron jobs (the work page's "Scheduled")

@Test func jobsListed() async throws {
    let (api, host) = client { _ in .init(body: StubURLProtocol.fixture("jobs.json")) }
    let jobs = try await api.jobs()
    #expect(StubURLProtocol.requests(host).first?.url?.path == "/api/jobs")
    #expect(jobs.map(\.id) == ["job_8c1f2a", "job_41d9e0"])
    #expect(jobs.map(\.name) == ["Morning brief", "Weekly invoices check"])
    #expect(jobs.map(\.paused) == [false, true])
    // ISO with an offset: 07:30 in +02:00 is 05:30 UTC.
    #expect(jobs[0].nextRunAt == Date(timeIntervalSince1970: 1_792_819_800))
    #expect(jobs[1].nextRunAt == nil)
    // A string schedule or an object one both read as text.
    #expect(jobs[0].schedule == "30 7 * * *")
    #expect(jobs[1].schedule == "0 9 * * 1")
}

@Test func jobsDecoderIsTolerant() throws {
    // Epoch seconds, `enabled: false` / `state: "paused"` for paused, `schedule_display` preferred, a bare array,
    // fractional seconds, a job without a name.
    let body = #"""
    [{"id":"a","name":"Backup","schedule":{"kind":"interval","minutes":15},"schedule_display":"every 15m","next_run_at":1792819800,"enabled":true},
     {"id":"b","schedule":"0 8 * * *","next_run_at":"2026-10-24T05:30:00.250Z","state":"paused"},
     {"id":"c","name":"Old","schedule":"0 8 * * *","enabled":false}]
    """#
    let jobs = try HermesJobs.parse(Data(body.utf8))
    #expect(jobs.map(\.paused) == [false, true, true])
    #expect(jobs[0].schedule == "every 15m")
    #expect(jobs[0].nextRunAt == Date(timeIntervalSince1970: 1_792_819_800))
    #expect(jobs[1].nextRunAt == Date(timeIntervalSince1970: 1_792_819_800.25))
    #expect(jobs[1].name == "b")
    let wrapped = try HermesJobs.parse(Data(#"{"jobs":[{"id":"x","name":"X","schedule":"daily"}]}"#.utf8))
    #expect(wrapped.map(\.id) == ["x"])
    #expect(throws: (any Error).self) { try HermesJobs.parse(Data("<html>".utf8)) }
}

@Test func jobScheduleReadsPlainly() {
    #expect(HermesJob.readable("30 7 * * *") == "every day 7:30")
    #expect(HermesJob.readable("0 9 * * 1-5") == "weekdays 9:00")
    #expect(HermesJob.readable("*/5 * * * *") == "*/5 * * * *")
    #expect(HermesJob.readable("every 15m") == "every 15m")
}
