import Foundation

// Vercel: the last 5 deployments, only the finished ones (READY, ERROR,
// CANCELED), a project filter for notifications, and one event when the newest watched deployment changes.

/// One finished Vercel deployment.
public struct VercelDeployment: Identifiable, Equatable, Sendable {
    public let id: String
    public let projectName: String
    /// Host only, e.g. "my-site-abc.vercel.app" (may be empty).
    public let url: String
    /// "READY", "ERROR" or "CANCELED".
    public let state: String
    public let createdAt: Date
    public let commitMessage: String?
    public let branch: String?

    public init(id: String, projectName: String, url: String, state: String, createdAt: Date,
                commitMessage: String?, branch: String?) {
        self.id = id
        self.projectName = projectName
        self.url = url
        self.state = state
        self.createdAt = createdAt
        self.commitMessage = commitMessage
        self.branch = branch
    }

    public var isSuccess: Bool { state == "READY" }
    public var statusLabel: String { isSuccess ? "Ready" : (state == "CANCELED" ? "Canceled" : "Error") }
    /// https://<url>, or nil when Vercel gave no URL.
    public var link: URL? { url.isEmpty ? nil : URL(string: "https://\(url)") }
}

public enum Vercel {
    public static let dashboard = URL(string: "https://vercel.com/dashboard")!
    public static let tokensPage = URL(string: "https://vercel.com/account/tokens")!
    static let terminalStates: Set<String> = ["READY", "ERROR", "CANCELED"]

    /// The `deployments` array of GET /v6/deployments, finished ones only, in Vercel's order (newest first).
    public static func parseDeployments(_ json: Any) -> [VercelDeployment] {
        guard let list = (json as? [String: Any])?["deployments"] as? [[String: Any]] else { return [] }
        return list.compactMap(parseDeployment).filter { terminalStates.contains($0.state) }
    }

    static func parseDeployment(_ d: [String: Any]) -> VercelDeployment? {
        guard let uid = d["uid"] as? String, let name = d["name"] as? String, let state = d["state"] as? String else { return nil }
        let ms = (d["createdAt"] as? Double) ?? (d["created"] as? Double) ?? 0
        let meta = d["meta"] as? [String: Any]
        let commit = meta?["githubCommitMessage"] as? String
            ?? meta?["gitlabCommitMessage"] as? String
            ?? meta?["bitbucketCommitMessage"] as? String
        let branch = meta?["githubCommitRef"] as? String
            ?? meta?["gitlabCommitRef"] as? String
            ?? meta?["bitbucketBranch"] as? String
        return VercelDeployment(id: uid, projectName: name, url: (d["url"] as? String) ?? "", state: state,
                                createdAt: Date(timeIntervalSince1970: ms / 1000), commitMessage: commit, branch: branch)
    }

    /// Project names from GET /v9/projects, sorted.
    public static func parseProjectNames(_ json: Any) -> [String] {
        guard let list = (json as? [String: Any])?["projects"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }.sorted()
    }

    /// Empty filter = every project.
    public static func filtered(_ deployments: [VercelDeployment], by filter: Set<String>) -> [VercelDeployment] {
        filter.isEmpty ? deployments : deployments.filter { filter.contains($0.projectName) }
    }

    /// A short age: "just now", "5m", "3h", "2d".
    public static func timeAgo(_ date: Date, now: Date = .now) -> String {
        let diff = now.timeIntervalSince(date)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        return "\(Int(diff / 86400))d"
    }

    /// "5m ago", but "just now" on its own.
    public static func agoPhrase(_ date: Date, now: Date = .now) -> String {
        let short = timeAgo(date, now: now)
        return short == "just now" ? short : short + " ago"
    }
}

/// The rule for the Vercel badge and sound: fire when the newest watched deployment's id changes.
/// The first load after launch (or after the token changes) is silent: it is the past, not news.
public struct VercelWatcher: Sendable {
    private var primed = false
    private var lastId = ""

    public init() {}

    public mutating func reset() {
        primed = false
        lastId = ""
    }

    public mutating func update(_ deployments: [VercelDeployment], filter: Set<String>) -> ServiceEvent? {
        let latest = Vercel.filtered(deployments, by: filter).first
        defer { primed = true }
        guard let latest else { return nil }
        guard latest.id != lastId else { return nil }
        lastId = latest.id
        guard primed else { return nil }
        return ServiceEvent(pill: "vercel", kind: latest.isSuccess ? .finished : .error,
                            detail: "\(latest.projectName) · \(latest.statusLabel)",
                            sound: latest.isSuccess ? .finish : .error)
    }
}

/// The project filter in Settings: a set of project names, empty = watch all. UserDefaults `vercelProjectFilter`,
/// a JSON array of names.
public enum VercelProjectFilter {
    public static let defaultsKey = "vercelProjectFilter"

    public static func load(_ defaults: UserDefaults = .standard) -> Set<String> {
        guard let data = defaults.data(forKey: defaultsKey),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names)
    }

    public static func save(_ filter: Set<String>, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(filter.sorted()) { defaults.set(data, forKey: defaultsKey) }
    }

    public static func isChecked(_ item: String, in filter: Set<String>) -> Bool {
        filter.isEmpty || filter.contains(item)
    }

    /// One checkbox changed. Unchecking from "all" keeps every other listed project; checking them all means all.
    public static func toggled(_ item: String, on: Bool, filter: Set<String>, items: [String]) -> Set<String> {
        var next = filter
        if on {
            next.insert(item)
        } else if next.isEmpty {
            next = Set(items).subtracting([item])
        } else {
            next.remove(item)
        }
        if !next.isEmpty, Set(items).isSubset(of: next) { return [] }
        return next
    }

    /// "Watching 2 of 5", only while a filter is set.
    public static func footer(filter: Set<String>, items: [String]) -> String? {
        filter.isEmpty ? nil : "Watching \(filter.count) of \(items.count)"
    }
}

/// Vercel's REST API with a personal token. Only api.vercel.com; the token is never logged.
public struct VercelClient: Sendable {
    public static let defaultBase = URL(string: "https://api.vercel.com")!

    let token: String
    let session: URLSession
    let base: URL

    public init(token: String, session: URLSession = .kobeEphemeral, base: URL = VercelClient.defaultBase) {
        self.token = token
        self.session = session
        self.base = base
    }

    /// GET /v6/deployments?limit=5, finished ones only.
    public func deployments() async throws -> [VercelDeployment] {
        Vercel.parseDeployments(try await get("/v6/deployments", query: "limit=5"))
    }

    /// GET /v9/projects?limit=100, names sorted.
    public func projects() async throws -> [String] {
        Vercel.parseProjectNames(try await get("/v9/projects", query: "limit=100"))
    }

    private func get(_ path: String, query: String) async throws -> Any {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw ServiceError.badKey }
        guard status == 200 else { throw ServiceError.failed("HTTP \(status)") }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ServiceError.failed("Vercel sent an unreadable answer.")
        }
    }
}
