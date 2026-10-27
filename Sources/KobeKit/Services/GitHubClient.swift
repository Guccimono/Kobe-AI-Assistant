import Foundation

// GitHub: REST for the star and repo counts, one GraphQL query for the pulse and
// one for the contribution calendar. Read-only; only ever talks to api.github.com. The token is never logged.

public struct GitHubClient: Sendable {
    public static let api = URL(string: "https://api.github.com")!

    private let token: String
    let session: URLSession
    private let base: URL

    public init(token: String, session: URLSession = .kobeEphemeral, base: URL = GitHubClient.api) {
        self.token = token
        self.session = session
        self.base = base
    }

    /// Repositories (public + owned private) and the stars across your owned repos.
    public func stats() async throws -> GitHubStats {
        let user = try await get("user", query: nil, timeout: 10) as? [String: Any] ?? [:]
        let publicRepos = user["public_repos"] as? Int ?? 0
        let privateRepos = user["owned_private_repos"] as? Int ?? user["total_private_repos"] as? Int ?? 0
        let repos = try await get("user/repos", query: "per_page=100&affiliation=owner&sort=pushed", timeout: 15)
            as? [[String: Any]] ?? []
        let stars = repos.reduce(0) { $0 + ($1["stargazers_count"] as? Int ?? 0) }
        return GitHubStats(totalRepos: publicRepos + privateRepos, totalStars: stars)
    }

    public func pulse() async throws -> GitHubPulse {
        let data = try await graphQL(Self.pulseQuery)
        guard let pulse = GitHubPulse.parse(data) else { throw ServiceError.failed("Unexpected answer from GitHub.") }
        return pulse
    }

    public func activity() async throws -> GitHubActivity {
        let data = try await graphQL(Self.activityQuery)
        guard let activity = GitHubActivity.parse(data) else { throw ServiceError.failed("Unexpected answer from GitHub.") }
        return activity
    }

    // MARK: Requests

    private func get(_ path: String, query: String?, timeout: TimeInterval) async throws -> Any {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        do { return try JSONSerialization.jsonObject(with: data) } catch {
            throw ServiceError.failed("Unexpected answer from GitHub.")
        }
    }

    /// POSTs a query. Partial GraphQL errors are tolerated when `data` is there; without it, the first error's message.
    private func graphQL(_ query: String) async throws -> Data {
        var request = URLRequest(url: base.appending(path: "graphql"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let data = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.failed("Unexpected answer from GitHub.")
        }
        if !(root["data"] is [String: Any]) {
            let message = (root["errors"] as? [[String: Any]])?.first?["message"] as? String
            throw ServiceError.failed(message ?? "Unexpected answer from GitHub.")
        }
        return data
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw ServiceError.badKey }
        guard (200..<300).contains(status) else { throw ServiceError.failed("HTTP \(status)") }
        return data
    }

    // MARK: Queries

    static let pulseQuery = """
    query {
      viewer {
        login
        pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number title url isDraft reviewDecision
            repository { nameWithOwner url }
            commits(last: 1) {
              nodes { commit { oid statusCheckRollup { state } } }
            }
          }
        }
        repositories(first: 10, ownerAffiliations: [OWNER], orderBy: {field: PUSHED_AT, direction: DESC}) {
          nodes {
            nameWithOwner url isArchived
            defaultBranchRef {
              name
              target { ... on Commit { oid statusCheckRollup { state } } }
            }
          }
        }
      }
      reviewRequested: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 20) {
        issueCount
        nodes {
          ... on PullRequest {
            number title url isDraft
            author { login }
            repository { nameWithOwner url }
          }
        }
      }
    }
    """

    static let activityQuery = """
    query {
      viewer {
        login
        contributionsCollection {
          contributionCalendar {
            totalContributions
            weeks {
              contributionDays {
                date contributionCount contributionLevel weekday
              }
            }
          }
        }
      }
    }
    """
}

// MARK: - Cadence

/// Timings, in seconds.
public enum GitHubSchedule {
    public static let statsFirst: TimeInterval = 7
    public static let statsEvery: TimeInterval = 300
    public static let pulseFirst: TimeInterval = 10
    public static let activityFirst: TimeInterval = 15
    public static let activityEvery: TimeInterval = 1800
    /// The card refreshes the pulse when it opens if it's older than this.
    public static let pulseMaxAge: TimeInterval = 60
    /// The Activity page refreshes the calendar if it's older than this.
    public static let activityMaxAge: TimeInterval = 300

    public static func nextPulse(hasPending: Bool) -> TimeInterval { hasPending ? 60 : 300 }
}

// MARK: - Links

/// Links the card opens: only https://github.com pages.
public enum GitHubLinks {
    public static let home = URL(string: "https://github.com")!
    public static let pulls = URL(string: "https://github.com/pulls")!
    public static let tokens = URL(string: "https://github.com/settings/tokens")!

    public static func pr(_ url: String) -> URL? { safe(url) }

    public static func actions(_ repoURL: String) -> URL? {
        safe(repoURL.hasSuffix("/") ? repoURL + "actions" : repoURL + "/actions")
    }

    public static func profile(_ login: String) -> URL? {
        guard !login.isEmpty, login.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return safe("https://github.com/\(login)")
    }

    private static func safe(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.host() == "github.com" else { return nil }
        return url
    }
}

// MARK: - Formatting

/// The card's copy.
public enum GitHubFormat {
    /// 1234 → "1.2k" from a thousand.
    public static func count(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    /// "owner/repo" → "repo".
    public static func shortRepo(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    /// "owner/repo#12" → "repo#12".
    public static func shortPR(_ id: String) -> String {
        guard let hash = id.lastIndex(of: "#") else { return id }
        return shortRepo(String(id[..<hash])) + id[hash...]
    }

    public static func prLabel(_ pr: GitHubPR) -> String { "\(shortRepo(pr.repo))#\(pr.number)" }

    /// The "My PRs" row: "0", "N", "N · running", "N · K failing".
    public static func myPRsValue(_ prs: [GitHubPR]) -> String {
        guard !prs.isEmpty else { return "0" }
        let failing = prs.filter { $0.ci == .failure }.count
        if failing > 0 { return "\(prs.count) · \(failing) failing" }
        if prs.contains(where: { $0.ci == .pending }) { return "\(prs.count) · running" }
        return "\(prs.count)"
    }

    /// The "Default branch CI" row: "N failing", "running", "all green", "no repos" or "unknown".
    public static func mainCIValue(_ repos: [GitHubRepoCI]) -> String {
        switch CIState.worst(repos.map(\.ci)) {
        case .failure: "\(repos.filter { $0.ci == .failure }.count) failing"
        case .pending: "running"
        case .success: "all green"
        case .unknown: repos.isEmpty ? "no repos" : "unknown"
        }
    }

    /// A default-branch row's word.
    public static func repoWord(_ ci: CIState) -> String? {
        switch ci {
        case .failure: "failing"
        case .pending: "running"
        case .success: "passing"
        case .unknown: nil
        }
    }

    /// "2026-10-05" → "Oct 5".
    public static func dayLabel(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), (1...12).contains(month), let day = Int(parts[2]) else { return date }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[month - 1]) \(day)"
    }

    public static func contributions(_ n: Int) -> String {
        switch n {
        case 0: "No contributions"
        case 1: "1 contribution"
        default: "\(n) contributions"
        }
    }

    public static func hover(_ day: ContributionDay) -> String { "\(dayLabel(day.date)) · \(contributions(day.count))" }

    /// 1234 → "1,234".
    public static func total(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func activityHeader(total n: Int, repos: Int?) -> String {
        if let repos { return "\(total(n)) past year · \(repos) repos" }
        return "\(total(n)) past year"
    }
}
