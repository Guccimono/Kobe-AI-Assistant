import Foundation

/// The shim: today's in-app services map what they fetched to the snapshot contract, so the pages can read the
/// folder before Kobe Agent writes it itself. Pure functions; the app writes their result with `SnapshotWriter`.
///
/// Status: `failed` when `error` is set (the data from the last good poll stays), `needs_you` for what wants the
/// user (a failed payment, unread messages, a review or a red default branch, a failed deploy), else `ok`.
public enum SnapshotBuilders {
    /// The longest WhatsApp preview written to disk: one line of the list, never a whole message body.
    public static let previewLimit = 100

    // MARK: Stripe

    /// `payments` newest first, the period's charges (its totals); `latest` the list the page shows (the newest
    /// whatever the period), `payments` when nil; `period` is "today", "7d" or "30d".
    public static func stripe(balance: StripeBalance?, payments: [StripePayment], period: String, error: String?,
                              nextPayout: Date? = nil, latest: [StripePayment]? = nil,
                              now: Date = .now) -> WidgetSnapshot<StripeSnapshotData> {
        let currency = balance?.currency ?? payments.first?.currency ?? "eur"
        let inPeriod = payments.filter { isIn(period, $0.createdAt, now: now) }
        let succeeded = inPeriod.filter { $0.isSuccess }
        let failed = inPeriod.filter { $0.status == "failed" }.count
        let total = succeeded.filter { $0.currency == currency }.reduce(0) { $0 + $1.amount }
        let data = StripeSnapshotData(
            period: period, total: total, count: succeeded.count, failed: failed, refunds: 0, currency: currency,
            // The client asks for one balance, available + pending together: it all shows as available.
            available: balance?.amount ?? 0, pending: 0, nextPayout: nextPayout,
            payments: (latest ?? payments).map {
                StripeSnapshotPayment(id: $0.id, customer: $0.description ?? "", plan: nil, amount: $0.amount,
                                      currency: $0.currency, status: $0.status, at: $0.createdAt, retryAt: nil,
                                      url: "https://dashboard.stripe.com/payments/\($0.id)")
            })
        let detail = succeeded.isEmpty
            ? "No payments \(periodLabel(period))"
            : "\(money(total, currency)) \(periodLabel(period)) · \(plural(succeeded.count, "payment"))"
        return envelope(.stripe, error: error, needsYou: failed > 0, okHeadline: "All good",
                        needsHeadline: "\(failed) failed", detail: detail, data: data, now: now)
    }

    // MARK: WhatsApp

    /// `conversations` as the list shows them (`WAInbox.visible(filters:)`), newest first.
    public static func whatsapp(conversations: [WAConversation], linked: Bool, error: String?,
                                now: Date = .now) -> WidgetSnapshot<WhatsAppSnapshotData> {
        let chats = conversations.map { c in
            let last = c.messages.last
            return WhatsAppSnapshotChat(
                jid: c.id, name: c.name, isGroup: c.isGroup, unread: c.unread, last: c.lastActivity,
                preview: last.map { clip(WAText.preview($0, isGroup: c.isGroup)) } ?? "",
                previewKind: last.map { kind($0.media) } ?? "text",
                mentionsMe: c.messages.contains { $0.mentionsMe && !$0.fromMe })
        }
        let unread = chats.reduce(0) { $0 + $1.unread }
        let data = WhatsAppSnapshotData(unread: unread, chats: chats)
        if error == nil, !linked {
            return WidgetSnapshot(id: .whatsapp, updatedAt: now, status: .notSetUp, headline: "Not linked",
                                  detail: "Link WhatsApp in Settings", data: data)
        }
        let detail = chats.isEmpty ? "No chats" : plural(chats.count, "chat")
        return envelope(.whatsapp, error: error, needsYou: unread > 0, okHeadline: "All read",
                        needsHeadline: "\(unread) unread", detail: detail, data: data, now: now)
    }

    /// WhatsApp's link as the shim sees it (the controller's `Link`, reduced to what decides the file).
    public enum WALink: Equatable, Sendable {
        case linked, needsQR, connecting, unreachable
        case failed(String)
    }

    /// The file for a link state, nil when nothing should be written yet: while connecting, or unreachable fewer
    /// than twice in a row (a gateway still starting), the last file stays instead of a false "Not linked".
    public static func whatsapp(conversations: [WAConversation], link: WALink, failures: Int, unreachable: String,
                                now: Date = .now) -> WidgetSnapshot<WhatsAppSnapshotData>? {
        switch link {
        case .connecting: return nil
        case .unreachable where failures < 2: return nil
        case .unreachable: return whatsapp(conversations: conversations, linked: false, error: unreachable, now: now)
        case .failed(let why): return whatsapp(conversations: conversations, linked: false, error: why, now: now)
        case .needsQR: return whatsapp(conversations: conversations, linked: false, error: nil, now: now)
        case .linked: return whatsapp(conversations: conversations, linked: true, error: nil, now: now)
        }
    }

    // MARK: GitHub

    public static func github(pulse: GitHubPulse?, activity: GitHubActivity?, stats: GitHubStats?, error: String?,
                              now: Date = .now) -> WidgetSnapshot<GitHubSnapshotData> {
        let reviews = (pulse?.toReview ?? []).map(item)
        let mains = (pulse?.mainCI ?? []).map(item)
        let myPRs = (pulse?.myPRs ?? []).map(item)
        // Review requests first, then red default branches.
        let needsYou = reviews + mains.filter { $0.state == "failing" }
        let data = GitHubSnapshotData(needsYou: needsYou, myPRs: myPRs, mains: mains,
                                      activity: activity?.lastDays(7).map(\.count) ?? [],
                                      total: activity?.total ?? 0, stars: stats?.totalStars ?? 0)
        let failing = myPRs.filter { $0.state == "failing" }.count
        return envelope(.github, error: error, needsYou: !needsYou.isEmpty,
                        okHeadline: failing > 0 ? "\(failing) failing" : "All green",
                        needsHeadline: "\(needsYou.count) need you",
                        detail: myPRs.isEmpty ? "No open PRs" : plural(myPRs.count, "open PR"), data: data, now: now)
    }

    // MARK: Vercel

    /// One row per project, its newest deployment; failures first, then newest first.
    public static func vercel(deployments: [VercelDeployment], error: String?,
                              now: Date = .now) -> WidgetSnapshot<VercelSnapshotData> {
        var newest: [String: VercelDeployment] = [:]
        for d in deployments where (newest[d.projectName]?.createdAt ?? .distantPast) < d.createdAt {
            newest[d.projectName] = d
        }
        let rows = newest.values.sorted {
            let (a, b) = ($0.state == "ERROR", $1.state == "ERROR")
            return a != b ? a : $0.createdAt > $1.createdAt
        }
        let projects = rows.map { d in
            VercelSnapshotProject(
                name: d.projectName, state: d.state.lowercased(), branch: d.branch,
                commit: d.commitMessage?.split(separator: "\n").first.map(String.init),
                at: d.createdAt, url: d.link?.absoluteString,
                // The client doesn't read Vercel's `target`: the default branch stands for production.
                isProduction: d.branch == "main" || d.branch == "master")
        }
        let failed = rows.filter { $0.state == "ERROR" }.count
        let detail = projects.isEmpty ? "No deployments" : plural(projects.count, "project")
        return envelope(.vercel, error: error, needsYou: failed > 0, okHeadline: "All live",
                        needsHeadline: "\(failed) failed", detail: detail, data: VercelSnapshotData(projects: projects),
                        now: now)
    }

    // MARK: Not set up

    public static func notSetUp(_ id: WidgetID, now: Date = .now) -> WidgetSnapshot<EmptyData> {
        WidgetSnapshot(id: id, updatedAt: now, status: .notSetUp, headline: "Not set up",
                       detail: "Add it in Settings", data: EmptyData())
    }

    // MARK: Helpers

    private static func envelope<D>(_ id: WidgetID, error: String?, needsYou: Bool, okHeadline: String,
                                    needsHeadline: String, detail: String, data: D,
                                    now: Date) -> WidgetSnapshot<D> {
        if let error {
            return WidgetSnapshot(id: id, updatedAt: now, status: .failed, headline: "Couldn't refresh",
                                  detail: detail, error: error, data: data)
        }
        return WidgetSnapshot(id: id, updatedAt: now, status: needsYou ? .needsYou : .ok,
                              headline: needsYou ? needsHeadline : okHeadline, detail: detail, data: data)
    }

    private static func isIn(_ period: String, _ date: Date, now: Date) -> Bool {
        switch period {
        case "7d": return now.timeIntervalSince(date) <= 7 * 86_400
        case "30d": return now.timeIntervalSince(date) <= 30 * 86_400
        default: return Calendar.current.isDate(date, inSameDayAs: now)
        }
    }

    private static func periodLabel(_ period: String) -> String {
        switch period {
        case "7d": "in 7 days"
        case "30d": "in 30 days"
        default: "today"
        }
    }

    /// "€", "$", "£", "MX$"; any other currency is its code and a space.
    public static func symbol(_ currency: String) -> String {
        switch currency.lowercased() {
        case "eur": "€"
        case "usd": "$"
        case "gbp": "£"
        case "mxn": "MX$"
        default: currency.uppercased() + " "
        }
    }

    /// "€1.28", "€128" (no cents when round), "MX$45", "CHF 3.50".
    public static func money(_ minor: Int, _ currency: String) -> String {
        let symbol = symbol(currency)
        let sign = minor < 0 ? "-" : ""
        let value = abs(minor)
        let cents = value % 100
        return sign + symbol + "\(value / 100)" + (cents == 0 ? "" : String(format: ".%02d", cents))
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    private static func clip(_ line: String) -> String {
        line.count <= previewLimit ? line : String(line.prefix(previewLimit - 1)) + "…"
    }

    private static func kind(_ media: WAMedia) -> String {
        switch media {
        case .none: "text"
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        case .voice: "voice"
        case .document: "document"
        case .sticker: "sticker"
        case .location: "location"
        case .contact: "contact"
        case .other: "other"
        }
    }

    private static func item(_ pr: GitHubPR) -> GitHubSnapshotItem {
        GitHubSnapshotItem(id: pr.id, repo: pr.repo, number: pr.number, title: pr.title, state: state(pr.ci),
                           branch: nil, author: nil, url: pr.url)
    }

    private static func item(_ ci: GitHubRepoCI) -> GitHubSnapshotItem {
        GitHubSnapshotItem(id: "main-\(ci.repo)", repo: ci.repo, number: nil, title: ci.branch, state: state(ci.ci),
                           branch: ci.branch, author: nil, url: ci.url)
    }

    private static func state(_ ci: CIState) -> String {
        switch ci {
        case .success: "passing"
        case .pending: "running"
        case .failure: "failing"
        case .unknown: "unknown"
        }
    }
}
