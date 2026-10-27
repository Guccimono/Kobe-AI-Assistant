import Foundation
import Synchronization

public enum ClaudeAnswer: Equatable, Sendable {
    case allow, deny
    /// The chosen option of a question.
    case option(String)
    /// Answer in Claude Code instead: the hook prints nothing.
    case none
}

/// Listens on a Unix socket only this user can open (mode 0600). kobe-hook writes one JSON line per event; for a
/// permission or a question the connection stays open and `reply` sends the answer back as one line.
///
/// Only kobe-hook is listened to: the peer's executable (its pid, from LOCAL_PEERPID) must end with `/kobe-hook`, or
/// with a suffix named in KOBE_SOCKET_PEER (tests). Anyone else is closed without a word. At most `maxConnections`
/// are served at a time, and a connection that doesn't send its line within `readTimeout` is dropped.
public final class ClaudeSocketServer: @unchecked Sendable {
    public typealias Reply = @Sendable (ClaudeAnswer) -> Void

    public static let maxConnections = 8
    public static let hookSuffix = "/kobe-hook"

    public let path: String
    /// A permission or question left unanswered is released after this long (the hook gives up first).
    public let answerTimeout: TimeInterval
    /// How long a connection may take to send its line.
    public let readTimeout: TimeInterval
    private let onEvent: @Sendable (ClaudeEvent, Reply?) -> Void
    private let listener = Mutex<Int32>(-1)
    private let active = Mutex<Int>(0)
    private let queue = DispatchQueue(label: "kobe.claude.socket", attributes: .concurrent)

    public init(path: String, answerTimeout: TimeInterval = 120, readTimeout: TimeInterval = 5,
                onEvent: @escaping @Sendable (ClaudeEvent, Reply?) -> Void) {
        self.path = path
        self.answerTimeout = answerTimeout
        self.readTimeout = readTimeout
        self.onEvent = onEvent
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        listener.withLock { $0 = fd }
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        let fd = listener.withLock { fd in defer { fd = -1 }; return fd }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(path)
    }

    private func isListening(_ fd: Int32) -> Bool { listener.withLock { $0 == fd } }

    private func acceptLoop(_ fd: Int32) {
        while isListening(fd) {
            let client = accept(fd, nil, nil)
            if client < 0 { if !isListening(fd) { return }; continue }
            // A hook that already gave up must never take the app down with SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let admitted = active.withLock { count in
                guard count < Self.maxConnections else { return false }
                count += 1
                return true
            }
            guard admitted, Self.isHook(client) else { close(client); if admitted { release() }; continue }
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    /// Closes a served connection and frees its slot. Every path out of `handle` ends here, once.
    private func finish(_ client: Int32) {
        close(client)
        release()
    }

    private func release() {
        active.withLock { $0 = max(0, $0 - 1) }
    }

    private func handle(_ client: Int32) {
        var deadline = timeval(tv_sec: Int(readTimeout), tv_usec: Int32((readTimeout - floor(readTimeout)) * 1_000_000))
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) && data.count < 1_000_000 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let line = data.prefix { $0 != 0x0A }
        guard let event = ClaudeEvent.parse(Data(line)) else { finish(client); return }
        guard event.waitsForAnswer else {
            finish(client)
            onEvent(event, nil)
            return
        }
        let answered = OnceFlag()
        let question: ClaudeQuestion? = if case .question(let q) = event { q } else { nil }
        onEvent(event) { [weak self] answer in
            guard answered.claim() else { return }
            if let text = Self.line(for: answer, question: question) {
                let bytes = Array((text + "\n").utf8)
                _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            }
            if let self { self.finish(client) } else { close(client) }
        }
        queue.asyncAfter(deadline: .now() + answerTimeout) { [weak self] in
            guard answered.claim() else { return }
            if let self { self.finish(client) } else { close(client) }
        }
    }

    // MARK: - Who is calling

    /// The executable of the process at the other end of `client`, from its pid.
    static func peerPath(of client: Int32) -> String? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let size = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard size > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `/kobe-hook`, plus the suffixes in KOBE_SOCKET_PEER (colon-separated), read each time so tests can set them.
    static var allowedPeerSuffixes: [String] {
        let extra = getenv("KOBE_SOCKET_PEER").map { String(cString: $0) } ?? ""
        return [hookSuffix] + extra.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    static func isHook(_ client: Int32) -> Bool {
        guard let path = peerPath(of: client) else { return false }
        return allowedPeerSuffixes.contains { path.hasSuffix($0) }
    }

    /// The answer as one JSON line. An option goes back under Claude Code's own question text and label (never the
    /// shown ones); a prompt with several questions is left to Claude Code, like no answer.
    static func line(for answer: ClaudeAnswer, question: ClaudeQuestion?) -> String? {
        switch answer {
        case .allow: return #"{"behavior":"allow"}"#
        case .deny: return #"{"behavior":"deny"}"#
        case .none: return #"{"decision":"ask"}"#
        case .option(let shown):
            guard let question, question.count == 1 else { return #"{"decision":"ask"}"# }
            let answers = [question.rawQuestion: question.rawLabel(for: shown) ?? shown]
            return (try? JSONSerialization.data(withJSONObject: ["decision": "answer", "answers": answers], options: .sortedKeys))
                .map { String(decoding: $0, as: UTF8.self) }
        }
    }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
