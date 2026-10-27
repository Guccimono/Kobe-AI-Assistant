import Foundation
import Testing
@testable import KobeKit

private func text(_ name: String) -> String { String(decoding: StubURLProtocol.fixture(name), as: UTF8.self) }

private func decodeAll(_ frames: [(event: String, data: String)]) -> [ChatEvent] {
    frames.compactMap { ChatEvent.decode(event: $0.event, data: $0.data) }
}

@Test func parsesSplitFrames() {
    let whole = text("chat_stream.sse")
    var a = SSEParser()
    let all = a.feed(whole)
    var b = SSEParser()
    var pieces: [(event: String, data: String)] = []
    var index = whole.startIndex
    while index < whole.endIndex {
        let end = whole.index(index, offsetBy: 7, limitedBy: whole.endIndex) ?? whole.endIndex
        pieces += b.feed(String(whole[index..<end]))
        index = end
    }
    #expect(all.count == 10)
    #expect(pieces.map(\.event) == all.map(\.event))
    #expect(pieces.map(\.data) == all.map(\.data))
}

@Test func ignoresKeepAlive() {
    var parser = SSEParser()
    #expect(parser.feed(": keepalive\n\n").isEmpty)
}

@Test func decodesFullTurn() {
    var parser = SSEParser()
    let events = decodeAll(parser.feed(text("chat_stream.sse")))
    let approval = ApprovalRequest(runID: "run_1", requestID: "r1", command: "touch /tmp/x", description: "Create a file")
    #expect(events == [
        .started(runID: "run_1"),
        .delta("Hel"), .delta("lo"),
        .tool(name: "terminal", phase: .started, preview: "touch /tmp/x"),
        .approval(approval),
        .tool(name: "terminal", phase: .completed, preview: "ok"),
        .completed(content: "Hello", model: "nemotron-3-ultra:free"),
        .done,
    ])
}

@Test func failedTurn() {
    var parser = SSEParser()
    let events = decodeAll(parser.feed(text("chat_stream_failed.sse")))
    #expect(events == [.started(runID: "run_2"), .failed("boom"), .done])
}

@Test func unknownEventIgnored() {
    #expect(ChatEvent.decode(event: "room.joined", data: "{}") == nil)
}

@Test func runFailedWithoutErrorText() {
    #expect(ChatEvent.decode(event: "run.failed", data: #"{"run_id":"run_3","partial":true}"#) == .failed("Kobe stopped before finishing."))
    #expect(ChatEvent.decode(event: "run.cancelled", data: #"{"run_id":"run_3"}"#) == .cancelled)
}

@Test func streamsOverHTTP() async throws {
    let stub = StubURLProtocol.make { _ in .init(body: StubURLProtocol.fixture("chat_stream.sse")) }
    let api = HermesClient(baseURL: stub.base, key: { "k" }, session: stub.session)
    let request = try await api.streamRequest(sessionID: "api_1", message: "Hi")
    #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    var events: [ChatEvent] = []
    for try await event in chatEvents(for: request, session: stub.session) { events.append(event) }
    #expect(events.first == .started(runID: "run_1"))
    #expect(events.last == .done)
    #expect(events.count == 8)
}

@Test func streamErrorStatusThrows() async {
    let stub = StubURLProtocol.make { _ in .init(status: 401, body: Data("{}".utf8)) }
    let api = HermesClient(baseURL: stub.base, key: { "k" }, session: stub.session)
    await #expect(throws: HermesError.unauthorized) {
        let request = try await api.streamRequest(sessionID: "api_1", message: "Hi")
        for try await _ in chatEvents(for: request, session: stub.session) {}
    }
}
