import Foundation

// GitHub's pulse: your open pull requests with their checks, the
// default-branch CI of your recently pushed repos, the pull requests waiting for your review, and what changed
// between two polls.

// MARK: - States

public enum CIState: String, Equatable, Sendable {
    case pending, success, failure, unknown

    public init(rawGitHub: String?) {
        switch rawGitHub?.uppercased() {
        case "PENDING", "EXPECTED": self = .pending
        case "SUCCESS": self = .success
        case "ERROR", "FAILURE": self = .failure
        default: self = .unknown
        }
    }

    /// The worst state: failure, then pending, then success, else unknown.
    public static func worst(_ states: [CIState]) -> CIState {
        if states.contains(.failure) { return .failure }
        if states.contains(.pending) { return .pending }
        if states.contains(.success) { return .success }
        return .unknown
    }
}

public enum ReviewState: String, Equatable, Sendable {
    case approved, changesRequested, pending, unknown

    public init(rawGitHub: String?) {
        switch rawGitHub?.uppercased() {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .pending
        default: self = .unknown
        }
    }
}

// MARK: - Models

public struct GitHubPR: Equatable, Sendable, Identifiable {
    /// "owner/repo#number".
    public var id: String
    public var title: String
    public var url: String
    /// "owner/repo".
    public var repo: String
    public var number: Int
    public var isDraft: Bool
    public var ci: CIState
    public var review: ReviewState
    /// The last commit's oid; nil when not fetched (review requests).
    public var headSha: String?

    public init(id: String, title: String, url: String, repo: String, number: Int, isDraft: Bool, ci: CIState,
                review: ReviewState, headSha: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.repo = repo
        self.number = number
        self.isDraft = isDraft
        self.ci = ci
        self.review = review
        self.headSha = headSha
    }
}

public struct GitHubRepoCI: Equatable, Sendable, Identifiable {
    public var repo: String
    public var url: String
    public var branch: String
    public var ci: CIState
    public var headSha: String?
    public var id: String { repo }

    public init(repo: String, url: String, branch: String, ci: CIState, headSha: String? = nil) {
        self.repo = repo
        self.url = url
        self.branch = branch
        self.ci = ci
        self.headSha = headSha
    }
}

public struct GitHubStats: Equatable, Sendable {
    public var totalRepos: Int
    public var totalStars: Int

    public init(totalRepos: Int, totalStars: Int) {
        self.totalRepos = totalRepos
        self.totalStars = totalStars
    }
}

/// The card's detail pages.
public enum GitHubDetailSection: Equatable, Sendable {
    case myPRs, toReview, mainCI, activity

    public var title: String {
        switch self {
        case .myPRs: "My PRs"
        case .toReview: "To review"
        case .mainCI: "Default branch CI"
        case .activity: "Activity"
        }
    }
}

public enum GitHubEvent: Equatable, Sendable {
    case ciFailed(prId: String)
    case ciPassed(prId: String)
    case mainFailed(repo: String)
    case reviewRequested(prId: String)
}

// MARK: - Pulse

public struct GitHubPulse: Equatable, Sendable {
    public var login: String
    public var myPRs: [GitHubPR]
    public var toReview: [GitHubPR]
    public var mainCI: [GitHubRepoCI]
    public var fetchedAt: Date

    public init(login: String, myPRs: [GitHubPR], toReview: [GitHubPR], mainCI: [GitHubRepoCI], fetchedAt: Date) {
        self.login = login
        self.myPRs = myPRs
        self.toReview = toReview
        self.mainCI = mainCI
        self.fetchedAt = fetchedAt
    }

    /// A PR's checks or a default branch are still running: poll again after 60 s instead of 300 s.
    public var hasPending: Bool {
        myPRs.contains { $0.ci == .pending } || mainCI.contains { $0.ci == .pending }
    }

    /// Parses the pulse GraphQL answer. Partial errors are fine as long as `data.viewer` is there.
    public static func parse(_ data: Data) -> GitHubPulse? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let viewer = dataNode["viewer"] as? [String: Any] else { return nil }
        let login = viewer["login"] as? String ?? ""

        var myPRs: [GitHubPR] = []
        var seenPR = Set<String>()
        for node in nodes(viewer["pullRequests"]) {
            guard let basics = prBasics(node), seenPR.insert(basics.id).inserted else { continue }
            let (id, title, url, repo, number) = basics
            let commit = ((node["commits"] as? [String: Any]).map(nodes)?.last)?["commit"] as? [String: Any]
            let rollup = commit?["statusCheckRollup"] as? [String: Any]
            myPRs.append(GitHubPR(id: id, title: title, url: url, repo: repo, number: number,
                                  isDraft: node["isDraft"] as? Bool ?? false,
                                  ci: CIState(rawGitHub: rollup?["state"] as? String),
                                  review: ReviewState(rawGitHub: node["reviewDecision"] as? String),
                                  headSha: commit?["oid"] as? String))
        }

        var mainCI: [GitHubRepoCI] = []
        for node in nodes(viewer["repositories"]) {
            if node["isArchived"] as? Bool ?? false { continue }
            guard let repo = node["nameWithOwner"] as? String, let url = node["url"] as? String,
                  let branchRef = node["defaultBranchRef"] as? [String: Any],
                  let branch = branchRef["name"] as? String else { continue }
            let target = branchRef["target"] as? [String: Any]
            let rollup = target?["statusCheckRollup"] as? [String: Any]
            mainCI.append(GitHubRepoCI(repo: repo, url: url, branch: branch,
                                       ci: CIState(rawGitHub: rollup?["state"] as? String),
                                       headSha: target?["oid"] as? String))
        }

        var toReview: [GitHubPR] = []
        var seenReview = Set<String>()
        for node in nodes(dataNode["reviewRequested"]) {
            guard let basics = prBasics(node), seenReview.insert(basics.id).inserted else { continue }
            let (id, title, url, repo, number) = basics
            toReview.append(GitHubPR(id: id, title: title, url: url, repo: repo, number: number,
                                     isDraft: node["isDraft"] as? Bool ?? false, ci: .unknown, review: .pending))
        }

        return GitHubPulse(login: login, myPRs: myPRs, toReview: toReview, mainCI: mainCI, fetchedAt: Date())
    }

    private static func nodes(_ connection: Any?) -> [[String: Any]] {
        (connection as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
    }

    private static func prBasics(_ node: [String: Any]) -> (id: String, title: String, url: String, repo: String, number: Int)? {
        guard let number = node["number"] as? Int, let title = node["title"] as? String,
              let url = node["url"] as? String,
              let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
        return ("\(repo)#\(number)", title, url, repo, number)
    }

    // MARK: Events

    /// What changed from `old` to `new`. Nothing on the first load (`old` nil).
    /// - Same commit (same SHA, or both nil): → failure from anything else is ciFailed; pending → success is ciPassed.
    /// - New PR or new commit: already success is ciPassed, already failure is ciFailed; still running waits.
    /// - Default branch: mainFailed on a new failure only, never a green alert.
    /// - A new id in toReview: reviewRequested.
    public static func events(old: GitHubPulse?, new: GitHubPulse) -> [GitHubEvent] {
        guard let old else { return [] }
        var result: [GitHubEvent] = []

        let oldPRs = Dictionary(old.myPRs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for pr in new.myPRs {
            if let prev = oldPRs[pr.id], prev.headSha == pr.headSha {
                if pr.ci == .failure, prev.ci != .failure {
                    result.append(.ciFailed(prId: pr.id))
                } else if pr.ci == .success, prev.ci == .pending {
                    result.append(.ciPassed(prId: pr.id))
                }
            } else if pr.ci == .success {
                result.append(.ciPassed(prId: pr.id))
            } else if pr.ci == .failure {
                result.append(.ciFailed(prId: pr.id))
            }
        }

        let oldRepos = Dictionary(old.mainCI.map { ($0.repo, $0) }, uniquingKeysWith: { first, _ in first })
        for repo in new.mainCI where repo.ci == .failure {
            if let prev = oldRepos[repo.repo], prev.headSha == repo.headSha, prev.ci == .failure { continue }
            result.append(.mainFailed(repo: repo.repo))
        }

        let oldReviews = Set(old.toReview.map(\.id))
        for pr in new.toReview where !oldReviews.contains(pr.id) {
            result.append(.reviewRequested(prId: pr.id))
        }
        return result
    }

    /// Reports only the highest-priority event per poll: a failure (error badge, error sound), else a review
    /// request (attention, question), else passed checks (finished, finish). Same rank: the first one wins.
    public static func serviceEvent(for events: [GitHubEvent], in pulse: GitHubPulse) -> ServiceEvent? {
        func rank(_ event: GitHubEvent) -> Int {
            switch event {
            case .ciFailed, .mainFailed: 3
            case .reviewRequested: 2
            case .ciPassed: 1
            }
        }
        guard let top = events.max(by: { rank($0) < rank($1) }),
              let best = events.first(where: { rank($0) == rank(top) }) else { return nil }
        switch best {
        case .ciFailed(let id):
            return ServiceEvent(pill: "github", kind: .error, detail: "Checks failing on \(GitHubFormat.shortPR(id))", sound: .error)
        case .mainFailed(let repo):
            var detail = "CI failing on \(GitHubFormat.shortRepo(repo))"
            if let branch = pulse.mainCI.first(where: { $0.repo == repo })?.branch { detail += " · \(branch)" }
            return ServiceEvent(pill: "github", kind: .error, detail: detail, sound: .error)
        case .reviewRequested(let id):
            return ServiceEvent(pill: "github", kind: .attention, detail: "Review requested: \(GitHubFormat.shortPR(id))", sound: .question)
        case .ciPassed(let id):
            return ServiceEvent(pill: "github", kind: .finished, detail: "Checks passed on \(GitHubFormat.shortPR(id))", sound: .finish)
        }
    }

    // MARK: Staleness

    /// True when never fetched or fetched more than `maxAge` seconds ago.
    public static func isStale(fetchedAt: Date?, now: Date = Date(), maxAge: TimeInterval) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > maxAge
    }
}
