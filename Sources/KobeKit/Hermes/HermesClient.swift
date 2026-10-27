import Foundation

/// Talks to the Hermes API server (default http://127.0.0.1:8642). Every request carries the bearer key;
/// without a key nothing is sent. The key is never logged.
public actor HermesClient {
    /// Read on every request, so a changed address applies without a restart.
    private nonisolated let base: @Sendable () -> URL
    public nonisolated var baseURL: URL { base() }
    private let key: @Sendable () -> String?
    public nonisolated let session: URLSession
    /// The assistant's name in the messages this client raises; the app updates it when the name changes.
    var copy = Copy(name: "Kobe")

    public init(baseURL: @escaping @Sendable () -> URL, key: @escaping @Sendable () -> String?, session: URLSession = .kobeLoopback) {
        self.base = baseURL
        self.key = key
        self.session = session
    }

    public init(baseURL: URL, key: @escaping @Sendable () -> String?, session: URLSession = .kobeLoopback) {
        self.init(baseURL: { baseURL }, key: key, session: session)
    }

    public func setCopy(_ copy: Copy) { self.copy = copy }

    public func listSessions(limit: Int = 50) async throws -> [HermesSession] {
        try decoded(SessionListWire.self, from: try await send("GET", "/api/sessions", query: ["limit": String(limit)])).data
    }

    /// The session whose title is exactly `title`, if any.
    public func findSession(title: String) async throws -> HermesSession? {
        let list = try decoded(SessionListWire.self, from: try await send("GET", "/api/sessions", query: ["title": title, "limit": "1"]))
        return list.data.first { $0.title == title }
    }

    /// Deletes a chat and its messages in Hermes. A chat in the middle of a turn answers 409.
    public func deleteSession(id: String) async throws {
        _ = try await send("DELETE", "/api/sessions/\(Self.escape(id))")
    }

    public func createSession(title: String?) async throws -> HermesSession {
        try await createSession(title: title, systemPrompt: nil)
    }

    /// `system_prompt` is sent only when given. Whether this Hermes build keeps it shows in the session's
    /// `has_system_prompt` (`GET /api/sessions`); a build that ignores the field still creates the session.
    public func createSession(title: String?, systemPrompt: String?) async throws -> HermesSession {
        var body: [String: String] = ["source": "api_server"]
        if let title { body["title"] = title }
        if let systemPrompt { body["system_prompt"] = systemPrompt }
        let data = try await send("POST", "/api/sessions", json: body)
        // Hermes answers {"object": "hermes.session", "session": {...}}; older builds sent the session bare.
        if let wrapped = try? decoded(SessionWire.self, from: data) { return wrapped.session }
        return try decoded(HermesSession.self, from: data)
    }

    /// Visible messages, oldest first.
    public func messages(sessionID: String) async throws -> [HermesMessage] {
        let data = try await send("GET", "/api/sessions/\(Self.escape(sessionID))/messages", query: ["order": "latest", "limit": "200"])
        return try decoded(MessageListWire.self, from: data).data
            .filter { $0.displayKind != "hidden" && !$0.content.isEmpty }
            .map { HermesMessage(id: $0.id, role: $0.role, content: $0.content, timestamp: $0.timestamp) }
            .sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }

    public func health() async throws -> HermesHealth {
        let wire = try decoded(HealthWire.self, from: try await send("GET", "/health/detailed"))
        let platforms = (wire.platforms ?? [:]).mapValues { $0.state == "connected" }
        return HermesHealth(reachable: true, version: wire.version, platforms: platforms)
    }

    /// The request that streams one chat turn as server-sent events.
    public func streamRequest(sessionID: String, message: String) throws -> URLRequest {
        var request = try makeRequest("POST", "/api/sessions/\(Self.escape(sessionID))/chat/stream", query: [:])
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": message])
        request.timeoutInterval = 3600
        return request
    }

    public func approve(runID: String, requestID: String?, choice: ApprovalChoice) async throws {
        var body = ["choice": choice.rawValue]
        if let requestID { body["request_id"] = requestID }
        _ = try await send("POST", "/v1/runs/\(Self.escape(runID))/approval", json: body)
    }

    /// Kobe Agent's cron jobs (`HermesJobs` reads the list). Asked only while the work page is open, on appear and
    /// ↻, never in the background.
    public func jobs() async throws -> [HermesJob] {
        let data = try await send("GET", "/api/jobs")
        do {
            return try HermesJobs.parse(data, copy: copy)
        } catch {
            throw HermesError.server(status: 200, code: "bad_response", message: "Unexpected answer from \(copy.name)")
        }
    }

    // MARK: - Plumbing

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String]) throws -> URLRequest {
        guard let key = key() else { throw HermesError.noKey }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], json: [String: String]? = nil) async throws -> Data {
        var request = try makeRequest(method, path, query: query)
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.map(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data, path: path) }
        return data
    }

    nonisolated static func map(_ error: URLError) -> HermesError {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
            .offline
        default:
            .server(status: 0, code: nil, message: error.localizedDescription)
        }
    }

    nonisolated static func error(status: Int, data: Data, path: String) -> HermesError {
        let body = try? JSONDecoder().decode(ErrorWire.self, from: data)
        switch status {
        case 401, 403: return .unauthorized
        case 404 where body?.error.code == "session_not_found": return .notFound(path)
        default: return .server(status: status, code: body?.error.code, message: body?.error.message ?? "HTTP \(status)")
        }
    }

    private func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw HermesError.server(status: 200, code: "bad_response", message: "Unexpected answer from \(copy.name)")
        }
    }
}
