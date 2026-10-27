import Foundation
import Testing
@testable import KobeKit

/// Writes one line to the socket and reads one line back, like kobe-hook does.
private func roundTrip(path: String, line: String) throws -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8.prefix($0.count - 1))) }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { throw URLError(.cannotConnectToHost) }
    let bytes = Array((line + "\n").utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while !reply.contains(0x0A) {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        reply.append(contentsOf: buffer[0..<n])
    }
    return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .newlines)
}

/// The executable of this test process: what the server sees at the other end of the socket.
private var ownPath: String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let size = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
    return String(decoding: buffer.prefix(Int(max(0, size))).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Like the app (KobeApp.main), the test process ignores SIGPIPE: these tests open and drop real sockets in parallel
/// with others. replyAfterTheHookLeftDoesNotKillTheApp was proven red without SO_NOSIGPIPE when run on its own.
/// The server only listens to kobe-hook; the test process is let in through the KOBE_SOCKET_PEER override.
private func tempSocket(peer: String? = nil) -> String {
    signal(SIGPIPE, SIG_IGN)
    setenv("KOBE_SOCKET_PEER", peer ?? ownPath, 1)
    return "/tmp/kobe-\(UUID().uuidString.prefix(8)).sock"
}

/// A connection that sends nothing and stays open.
private func idleConnection(path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8.prefix($0.count - 1))) }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    return fd
}

/// One at a time: these tests open real sockets and file descriptors.
@Suite(.serialized)
struct ClaudeSocketTests {
    @Test func socketRoundTrip() throws {
    let path = tempSocket()
    let server = ClaudeSocketServer(path: path) { event, reply in
        if case .permission = event { reply?(.allow) }
    }
    try server.start()
    defer { server.stop() }
    let line = String(decoding: StubURLProtocol.fixture("hook_permission_bash.json"), as: UTF8.self)
    #expect(try roundTrip(path: path, line: line) == #"{"behavior":"allow"}"#)
}

    @Test func questionAnswerCarriesTheQuestion() throws {
    let path = tempSocket()
    let server = ClaudeSocketServer(path: path) { _, reply in reply?(.option("Skip")) }
    try server.start()
    defer { server.stop() }
    let line = String(decoding: StubURLProtocol.fixture("hook_question.json"), as: UTF8.self)
    let reply = try roundTrip(path: path, line: line)
    let json = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
    #expect(json["decision"] as? String == "answer")
    #expect((json["answers"] as? [String: String]) == ["Which approach should I take?": "Skip"])
}

    @Test func questionAnswerCarriesTheRawQuestionAndLabel() throws {
    let path = tempSocket()
    // The notch shows the visible text and answers with it; Claude Code must get the bytes it sent.
    let server = ClaudeSocketServer(path: path) { _, reply in reply?(.option("Yes✔⟨U+FE0F⟩")) }
    try server.start()
    defer { server.stop() }
    let line = """
    {"hook_event_name":"PreToolUse","cwd":"/x/site","tool_name":"AskUserQuestion","_ask":true,"tool_input":{"questions":[{"question":"Deploy\\u00a0now?","options":[{"label":"Yes\\u2714\\ufe0f"},{"label":"No"}]}]}}
    """
    let reply = try roundTrip(path: path, line: line)
    let json = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
    #expect((json["answers"] as? [String: String]) == ["Deploy\u{00A0}now?": "Yes✔\u{FE0F}"])
}

    @Test func severalQuestionsAreLeftToClaudeCode() throws {
    let path = tempSocket()
    let server = ClaudeSocketServer(path: path) { _, reply in reply?(.option("1")) }
    try server.start()
    defer { server.stop() }
    let line = """
    {"hook_event_name":"PreToolUse","cwd":"/x/site","tool_name":"AskUserQuestion","_ask":true,"tool_input":{"questions":[{"question":"A?","options":[{"label":"1"}]},{"question":"B?","options":[{"label":"2"}]}]}}
    """
    #expect(try roundTrip(path: path, line: line) == #"{"decision":"ask"}"#)
}

    @Test func informationalEventsGetNoReplyChannel() throws {
    let path = tempSocket()
    let got = Locked<Bool?>(nil)
    let server = ClaudeSocketServer(path: path) { _, reply in got.set(reply == nil) }
    try server.start()
    defer { server.stop() }
    let line = String(decoding: StubURLProtocol.fixture("hook_stop.json"), as: UTF8.self)
    #expect(try roundTrip(path: path, line: line) == "")
    #expect(got.get() == true)
}

    @Test func socketIsPrivate() throws {
    let path = tempSocket()
    let server = ClaudeSocketServer(path: path) { _, _ in }
    try server.start()
    defer { server.stop() }
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

    @Test func aStrangerAtTheSocketIsIgnored() throws {
    let path = tempSocket(peer: "/nobody/kobe-hook-impostor")
    let got = Locked<Bool>(false)
    let server = ClaudeSocketServer(path: path) { _, reply in got.set(true); reply?(.allow) }
    try server.start()
    defer { server.stop() }
    let line = String(decoding: StubURLProtocol.fixture("hook_permission_bash.json"), as: UTF8.self)
    #expect(try roundTrip(path: path, line: line) == "")
    #expect(got.get() == false)
}

    @Test func idleConnectionsAreCappedAndDropped() throws {
    let path = tempSocket()
    let server = ClaudeSocketServer(path: path, readTimeout: 0.3) { _, reply in reply?(.allow) }
    try server.start()
    defer { server.stop() }
    let idle = (0..<ClaudeSocketServer.maxConnections).map { _ in idleConnection(path: path) }
    defer { idle.forEach { close($0) } }
    usleep(100_000)
    let line = String(decoding: StubURLProtocol.fixture("hook_permission_bash.json"), as: UTF8.self)
    #expect(try roundTrip(path: path, line: line) == "")  // one too many: refused at once
    usleep(500_000)  // the idle ones hit the read deadline and are dropped
    #expect(try roundTrip(path: path, line: line) == #"{"behavior":"allow"}"#)
}

    @Test func unansweredQuestionIsReleased() throws {
    let path = tempSocket()
    let server = ClaudeSocketServer(path: path, answerTimeout: 0.2) { _, _ in }  // never replies
    try server.start()
    defer { server.stop() }
    let line = String(decoding: StubURLProtocol.fixture("hook_question.json"), as: UTF8.self)
    #expect(try roundTrip(path: path, line: line) == "")  // the connection closes on its own
}

    @Test func replyAfterTheHookLeftDoesNotKillTheApp() throws {
    let path = tempSocket()
    let saved = Locked<ClaudeSocketServer.Reply?>(nil)
    let server = ClaudeSocketServer(path: path) { _, reply in saved.set(reply) }
    try server.start()
    defer { server.stop() }
    // The hook writes its question and gives up at once.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8.prefix($0.count - 1))) }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    let line = Array((String(decoding: StubURLProtocol.fixture("hook_permission_bash.json"), as: UTF8.self) + "\n").utf8)
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    close(fd)
    for _ in 0..<100 where saved.get() == nil { usleep(10_000) }
    usleep(50_000)
    saved.get()?(.allow)  // a SIGPIPE here would end the test process
    usleep(50_000)
    saved.get()?(.allow)
    #expect(saved.get() != nil)
}
}

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}
