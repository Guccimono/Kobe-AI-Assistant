import Foundation
import Testing
@testable import KobeKit

struct NowRankerTests {
    private let now = Date(timeIntervalSince1970: 1_792_765_690)   // 2026-10-23 14:28:10 UTC

    private func stripe(_ payments: [StripeSnapshotPayment]) -> WidgetSnapshot<StripeSnapshotData> {
        WidgetSnapshot(id: .stripe, updatedAt: now, status: .ok, headline: "", detail: "",
                       data: StripeSnapshotData(period: "today", total: 0, count: 0, failed: 0, refunds: 0, currency: "eur",
                                                available: 0, pending: 0, nextPayout: nil, payments: payments))
    }

    private func payment(_ id: String, _ status: String, ago: TimeInterval = 600) -> StripeSnapshotPayment {
        StripeSnapshotPayment(id: id, customer: "Casa \(id)", plan: "Pro", amount: 4900, currency: "eur", status: status,
                              at: now.addingTimeInterval(-ago), retryAt: nil, url: "https://dashboard.stripe.com/\(id)")
    }

    private func whatsapp(_ chats: [WhatsAppSnapshotChat]) -> WidgetSnapshot<WhatsAppSnapshotData> {
        WidgetSnapshot(id: .whatsapp, updatedAt: now, status: .ok, headline: "", detail: "",
                       data: WhatsAppSnapshotData(unread: chats.map(\.unread).reduce(0, +), chats: chats))
    }

    private func chat(_ name: String, unread: Int = 1, group: Bool = false, mention: Bool = false,
                      ago: TimeInterval = 60) -> WhatsAppSnapshotChat {
        WhatsAppSnapshotChat(jid: "\(name)@s.whatsapp.net", name: name, isGroup: group, unread: unread,
                             last: now.addingTimeInterval(-ago), preview: "Hi from \(name)", previewKind: "text",
                             mentionsMe: mention)
    }

    private func github(needsYou: [GitHubSnapshotItem]) -> WidgetSnapshot<GitHubSnapshotData> {
        WidgetSnapshot(id: .github, updatedAt: now, status: .ok, headline: "", detail: "",
                       data: GitHubSnapshotData(needsYou: needsYou, myPRs: [], mains: [], activity: [], total: 0, stars: 0))
    }

    private func review(_ n: Int) -> GitHubSnapshotItem {
        GitHubSnapshotItem(id: "pr\(n)", repo: "menuly-v4", number: n, title: "Fix \(n)", state: "passing", branch: nil,
                           author: "ana", url: "https://github.com/x/menuly-v4/pull/\(n)")
    }

    private func vercel(_ states: [String]) -> WidgetSnapshot<VercelSnapshotData> {
        WidgetSnapshot(id: .vercel, updatedAt: now, status: .ok, headline: "", detail: "",
                       data: VercelSnapshotData(projects: states.enumerated().map {
                           VercelSnapshotProject(name: "site\($0.offset)", state: $0.element, branch: "main", commit: nil,
                                                 at: now, url: "https://site\($0.offset).vercel.app", isProduction: true)
                       }))
    }

    @Test func capsAtSix() {
        let result = NowRanker.compose(stripe: stripe([payment("a", "failed"), payment("b", "failed")]),
                                       whatsapp: whatsapp((0..<5).map { chat("c\($0)", ago: Double($0) * 60) }),
                                       github: github(needsYou: [review(1), review(2)]),
                                       vercel: vercel(["error"]), now: now)
        #expect(result.needsYou.count + result.clients.count == NowRanker.limit)
        #expect(NowRanker.limit == 6)
        #expect(result.needsYou.count == 5 && result.clients.count == 1)
    }

    @Test func groupsOnlyWhenNonEmpty() {
        let onlyClients = NowRanker.compose(stripe: nil, whatsapp: whatsapp([chat("Lea")]), github: nil, vercel: nil, now: now)
        #expect(onlyClients.needsYou.isEmpty && onlyClients.clients.count == 1)
        #expect(onlyClients.current == nil)
        let onlyNeeds = NowRanker.compose(stripe: nil, whatsapp: nil, github: nil, vercel: vercel(["error", "ready"]), now: now)
        #expect(onlyNeeds.needsYou.map(\.source) == [.vercel] && onlyNeeds.clients.isEmpty)
    }

    @Test func needsYouBeforeClients() {
        // The six slots go to Needs you first; clients get what is left, WhatsApp newest first, then payments.
        let result = NowRanker.compose(stripe: stripe([payment("paid", "succeeded"), payment("bad", "failed")]),
                                       whatsapp: whatsapp([chat("Old", ago: 600), chat("New", ago: 30),
                                                           chat("Team", group: true, mention: true)]),
                                       github: github(needsYou: [review(212)]), vercel: vercel(["error"]), now: now)
        #expect(result.needsYou.map(\.source) == [.stripe, .github, .vercel, .whatsapp])
        #expect(result.needsYou.allSatisfy { $0.tint == NowRanker.needsYouTint })
        #expect(result.clients.map(\.title) == ["New", "Old"])
        #expect(result.needsYou[0].action == .open && result.needsYou[1].action == .review
                && result.needsYou[2].action == .visit && result.needsYou[3].action == .reply)
        #expect(result.clients[0].action == .reply)
        // A payment from yesterday is not "today": it stays off the list.
        let old = NowRanker.compose(stripe: stripe([payment("y", "succeeded", ago: 86_400 * 2)]),
                                    whatsapp: nil, github: nil, vercel: nil, now: now)
        #expect(old.clients.isEmpty)
        let paid = NowRanker.compose(stripe: stripe([payment("t", "succeeded")]), whatsapp: nil, github: nil, vercel: nil, now: now)
        #expect(paid.clients.map(\.title) == ["Casa t paid €49"])
        #expect(paid.clients[0].action == .visit && paid.clients[0].source == .stripe)
        #expect(paid.clients[0].url == "https://dashboard.stripe.com/t")
        #expect(result.needsYou[1].url == "https://github.com/x/menuly-v4/pull/212")
        #expect(result.needsYou[2].url == "https://site0.vercel.app")
    }

    @Test func whatsappGroupsAreNotClients() {
        let result = NowRanker.compose(stripe: nil, whatsapp: whatsapp([chat("Family", unread: 4, group: true),
                                                                        chat("Read", unread: 0),
                                                                        chat("Ana", unread: 2)]),
                                       github: nil, vercel: nil, now: now)
        #expect(result.clients.map(\.title) == ["Ana"])
        #expect(result.needsYou.isEmpty)
    }

    @Test func emptyWhenAllQuiet() {
        let result = NowRanker.compose(stripe: stripe([]), whatsapp: whatsapp([]), github: github(needsYou: []),
                                       vercel: vercel(["ready"]), now: now)
        #expect(result.needsYou.isEmpty && result.clients.isEmpty && result.current == nil)
        #expect(NowRanker.emptyCopy == "Nothing needs you.")
    }

    @Test func eyebrowMeta() {
        #expect(NowRanker.meta(updatedAt: nil, now: now) == "by Kobe")
        #expect(NowRanker.meta(updatedAt: now.addingTimeInterval(-20), now: now) == "by Kobe · just now")
        #expect(NowRanker.meta(updatedAt: now.addingTimeInterval(-125), now: now) == "by Kobe · 2 min ago")
        // The newest of the inputs counts when the shim composes the list.
        let s = stripe([])
        #expect(NowRanker.updatedAt(stripe: s, whatsapp: nil, github: nil, vercel: nil) == now)
        #expect(NowRanker.updatedAt(stripe: nil, whatsapp: nil, github: nil, vercel: nil) == nil)
    }

    // MARK: The calendar and overdue reminders (Mac connectors)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func agenda(_ events: [AgendaEvent]) -> WidgetSnapshot<AgendaSnapshotData> {
        WidgetSnapshot(id: .agenda, updatedAt: now.addingTimeInterval(30), status: .ok, headline: "", detail: "",
                       data: AgendaSnapshotData(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(86_400 * 30),
                                                calendars: [], events: events))
    }

    private func event(_ title: String, in start: TimeInterval, for length: TimeInterval = 1800,
                       allDay: Bool = false) -> AgendaEvent {
        AgendaEvent(id: title, title: title, calendar: "cal", start: now.addingTimeInterval(start),
                    end: now.addingTimeInterval(start + length), allDay: allDay)
    }

    private func reminders(_ items: [ReminderItem]) -> WidgetSnapshot<RemindersSnapshotData> {
        WidgetSnapshot(id: .reminders, updatedAt: now, status: .ok, headline: "", detail: "",
                       data: RemindersSnapshotData(overdue: 0, reminders: items))
    }

    private func compose(agenda a: WidgetSnapshot<AgendaSnapshotData>? = nil,
                         reminders r: WidgetSnapshot<RemindersSnapshotData>? = nil,
                         github g: WidgetSnapshot<GitHubSnapshotData>? = nil) -> NowSnapshotData {
        NowRanker.compose(stripe: nil, whatsapp: nil, github: g, vercel: nil, agenda: a, reminders: r, now: now,
                          calendar: utc)
    }

    @Test func currentEventIsTheRunningOne() {
        // now is 14:28:10 UTC; Standup runs 14:13:10–14:43:10.
        let result = compose(agenda: agenda([event("Standup", in: -900), event("Lunch", in: 1200)]))
        #expect(result.current?.title == "Standup" && result.current?.source == .agenda)
        #expect(result.current?.detail == "now · until 14:43")
        #expect(result.current?.until == now.addingTimeInterval(900))
    }

    @Test func nextWithinTheHourIsCurrent() {
        let result = compose(agenda: agenda([event("Lunch", in: 1200)]))
        #expect(result.current?.title == "Lunch" && result.current?.detail == "in 20 min · 14:48")
    }

    @Test func nextLaterIsNotCurrent() {
        #expect(compose(agenda: agenda([event("Late", in: 61 * 60)])).current == nil)
        #expect(compose(agenda: agenda([event("Past", in: -7200)])).current == nil)
    }

    @Test func allDayIsNeverCurrent() {
        #expect(compose(agenda: agenda([event("Day off", in: -3600, for: 86_400, allDay: true)])).current == nil)
    }

    @Test func overdueRemindersLeadNeedsYou() {
        let items = [
            ReminderItem(id: "r1", title: "Send the invoice", list: "Work", listColor: "#F5A524",
                         due: now.addingTimeInterval(-86_400 - 3600), dueHasTime: true, completed: false),
            ReminderItem(id: "r2", title: "Call the bank", list: "Work", listColor: "#F5A524",
                         due: now.addingTimeInterval(-1800), dueHasTime: true, completed: false),
            ReminderItem(id: "r3", title: "Later", list: "Work", listColor: "#F5A524",
                         due: now.addingTimeInterval(3600), dueHasTime: true, completed: false),
            ReminderItem(id: "r4", title: "Done already", list: "Work", listColor: "#F5A524",
                         due: now.addingTimeInterval(-3600), dueHasTime: true, completed: true),
        ]
        let result = compose(reminders: reminders(items), github: github(needsYou: [review(7)]))
        #expect(result.needsYou.map(\.source) == [.reminders, .reminders, .github])
        #expect(result.needsYou[0].title == "Send the invoice" && result.needsYou[0].detail == "due yesterday 13:28")
        #expect(result.needsYou[1].detail == "due 13:58")
        #expect(result.needsYou.count + result.clients.count <= NowRanker.limit)
    }

    @Test func updatedAtTakesTheMacSnapshotsToo() {
        let a = agenda([])
        #expect(NowRanker.updatedAt(stripe: nil, whatsapp: nil, github: github(needsYou: []), vercel: nil, agenda: a,
                                    reminders: nil) == a.updatedAt)
    }
}
