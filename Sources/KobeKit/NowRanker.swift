import Foundation

/// Home's "Now" list until Kobe Agent writes `now.json` itself: built from the four shimmed snapshots with the
/// rules of spec §6.1. Pure, so the order is tested; the app calls it only when `now` is missing or stale.
///
/// Needs you, in this order: failed Stripe payments today, GitHub's needs-you (review requests, red default
/// branches), failed Vercel deploys, WhatsApp chats that mention you. Clients: unread one-to-one WhatsApp chats
/// (newest first), then today's Stripe payments. Six rows at most, Needs you first. Overdue reminders lead Needs
/// you; `current` is the running event, else the next one within the hour (all-day events never count).
public enum NowRanker {
    public static let limit = 6
    public static let emptyCopy = "Nothing needs you."
    /// `NowRow.tint` for rows under Needs you; the pane draws it amber.
    public static let needsYouTint = "needs_you"

    public static func compose(stripe: WidgetSnapshot<StripeSnapshotData>?,
                               whatsapp: WidgetSnapshot<WhatsAppSnapshotData>?,
                               github: WidgetSnapshot<GitHubSnapshotData>?,
                               vercel: WidgetSnapshot<VercelSnapshotData>?,
                               agenda: WidgetSnapshot<AgendaSnapshotData>? = nil,
                               reminders: WidgetSnapshot<RemindersSnapshotData>? = nil,
                               now: Date = .now, calendar: Calendar = .current) -> NowSnapshotData {
        let today = (stripe?.data.payments ?? []).filter { Calendar.current.isDate($0.at, inSameDayAs: now) }
        let chats = (whatsapp?.data.chats ?? []).filter { $0.unread > 0 }
        let mentions = chats.filter(\.mentionsMe)

        let overdue = (reminders?.data.reminders ?? [])
            .filter { !$0.completed && ReminderGroups.isOverdue($0, now: now, calendar: calendar) }
            .sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }

        var needsYou: [NowRow] = []
        needsYou += overdue.map { overdueReminder($0, now: now, calendar: calendar) }
        needsYou += today.filter { $0.status == "failed" }.map(failedPayment)
        needsYou += (github?.data.needsYou ?? []).map(githubItem)
        needsYou += (vercel?.data.projects ?? []).filter { $0.state.lowercased() == "error" }.map(failedDeploy)
        needsYou += mentions.map(mention)

        // A chat that mentions you is already under Needs you; groups are never clients.
        var clients: [NowRow] = []
        clients += chats.filter { !$0.isGroup && !$0.mentionsMe }.sorted { $0.last > $1.last }.map(message)
        clients += today.filter { $0.status == "succeeded" }.map(payment)

        let needs = Array(needsYou.prefix(limit))
        let current = currentEvent(agenda?.data.events ?? [], now: now, calendar: calendar)
        return NowSnapshotData(current: current, needsYou: needs, clients: Array(clients.prefix(limit - needs.count)),
                               brief: nil)
    }

    /// The eyebrow's right side: "by Kobe · 2 min ago", or "by Kobe" before anything was read.
    public static func meta(updatedAt: Date?, now: Date = .now, copy: Copy = Copy(name: "Kobe")) -> String {
        guard let updatedAt else { return "by \(copy.name)" }
        return "by \(copy.name) · " + SnapshotRules.ago(max(now.timeIntervalSince(updatedAt), 0))
    }

    /// When the shim's list was last true: the newest of its inputs.
    public static func updatedAt(stripe: WidgetSnapshot<StripeSnapshotData>?,
                                 whatsapp: WidgetSnapshot<WhatsAppSnapshotData>?,
                                 github: WidgetSnapshot<GitHubSnapshotData>?,
                                 vercel: WidgetSnapshot<VercelSnapshotData>?,
                                 agenda: WidgetSnapshot<AgendaSnapshotData>? = nil,
                                 reminders: WidgetSnapshot<RemindersSnapshotData>? = nil) -> Date? {
        [stripe?.updatedAt, whatsapp?.updatedAt, github?.updatedAt, vercel?.updatedAt, agenda?.updatedAt,
         reminders?.updatedAt].compactMap { $0 }.max()
    }

    /// The running event, else the next one starting within the hour.
    static func currentEvent(_ events: [AgendaEvent], now: Date, calendar: Calendar) -> NowRow? {
        let timed = events.filter { !$0.allDay }.sorted { $0.start < $1.start }
        if let e = timed.first(where: { $0.start <= now && now < $0.end }) {
            return NowRow(id: "agenda:\(e.id)", source: .agenda, title: e.title,
                          detail: "now · until \(MacBuilders.clock(e.end, calendar))", tint: nil, action: .open,
                          until: e.end)
        }
        guard let e = timed.first(where: { $0.start > now && $0.start.timeIntervalSince(now) <= 3600 }) else { return nil }
        let minutes = max(Int((e.start.timeIntervalSince(now) / 60).rounded()), 1)
        return NowRow(id: "agenda:\(e.id)", source: .agenda, title: e.title,
                      detail: "in \(minutes) min · \(MacBuilders.clock(e.start, calendar))", tint: nil, action: .open,
                      until: e.end)
    }

    // MARK: Rows

    /// "due 09:00", "due yesterday 10:00", "due yesterday", "due 3 days ago".
    private static func overdueReminder(_ r: ReminderItem, now: Date, calendar: Calendar) -> NowRow {
        let due = r.due ?? now
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: due),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let time = r.dueHasTime ? " " + MacBuilders.clock(due, calendar) : ""
        let when = switch days {
        case ...0: "due" + time
        case 1: "due yesterday" + time
        default: "due \(days) days ago"
        }
        return NowRow(id: "reminders:\(r.id)", source: .reminders, title: r.title, detail: when, tint: needsYouTint,
                      action: .open, until: nil)
    }

    private static func failedPayment(_ p: StripeSnapshotPayment) -> NowRow {
        NowRow(id: "stripe:\(p.id)", source: .stripe, title: "\(p.customer) payment failed",
               detail: [SnapshotBuilders.money(p.amount, p.currency), p.plan].compactMap { $0 }.joined(separator: " · "),
               tint: needsYouTint, action: .open, until: nil, url: p.url)
    }

    private static func githubItem(_ item: GitHubSnapshotItem) -> NowRow {
        // A PR number means a review request; without one it is a red default branch.
        let title = item.number.map { "\(item.repo) #\($0) waits for review" } ?? "\(item.repo) \(item.branch ?? "main") is failing"
        let detail = [item.title, item.author].compactMap { $0 }.joined(separator: " · ")
        return NowRow(id: "github:\(item.id)", source: .github, title: title, detail: detail, tint: needsYouTint,
                      action: .review, until: nil, url: item.url)
    }

    private static func failedDeploy(_ p: VercelSnapshotProject) -> NowRow {
        NowRow(id: "vercel:\(p.name)", source: .vercel, title: "\(p.name) deploy failed",
               detail: p.commit ?? p.branch ?? "Vercel", tint: needsYouTint, action: .visit, until: nil, url: p.url)
    }

    private static func mention(_ c: WhatsAppSnapshotChat) -> NowRow {
        NowRow(id: "whatsapp:\(c.jid)", source: .whatsapp, title: c.name, detail: "Mentioned you · \(c.preview)",
               tint: needsYouTint, action: .reply, until: nil)
    }

    private static func message(_ c: WhatsAppSnapshotChat) -> NowRow {
        NowRow(id: "whatsapp:\(c.jid)", source: .whatsapp, title: c.name, detail: c.preview, tint: nil, action: .reply,
               until: nil)
    }

    private static func payment(_ p: StripeSnapshotPayment) -> NowRow {
        let time = clock.string(from: p.at)
        return NowRow(id: "stripe:\(p.id)", source: .stripe,
                      title: "\(p.customer) paid \(SnapshotBuilders.money(p.amount, p.currency))",
                      detail: [p.plan.map { "\($0) plan" }, time].compactMap { $0 }.joined(separator: " · "),
                      tint: nil, action: .visit, until: nil, url: p.url)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
