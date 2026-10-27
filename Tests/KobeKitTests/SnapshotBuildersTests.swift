import Foundation
import Testing
@testable import KobeKit

struct SnapshotBuildersTests {
    /// Whole seconds, so an encode/decode round trip (ISO 8601 without fractions) compares equal.
    private let now = Date(timeIntervalSince1970: 1_792_765_690)   // 2026-10-23 14:28:10 UTC

    private func payment(_ id: String, _ amount: Int, _ status: String, ago: TimeInterval = 60) -> StripePayment {
        StripePayment(id: id, amount: amount, currency: "eur", description: "Café \(id)",
                      createdAt: now.addingTimeInterval(-ago), status: status)
    }

    @Test func stripeBuilderHeadlineAndStatus() throws {
        let payments = [payment("ch_1", 50, "succeeded"), payment("ch_2", 40, "succeeded"),
                        payment("ch_3", 38, "succeeded"), payment("ch_4", 900, "failed")]
        let s = SnapshotBuilders.stripe(balance: StripeBalance(amount: 45_000, currency: "eur"), payments: payments,
                                        period: "today", error: nil, now: now)
        #expect(s.id == .stripe && s.status == .needsYou)
        #expect(s.headline == "1 failed")
        #expect(s.detail == "€1.28 today · 3 payments")
        #expect(s.data.total == 128 && s.data.count == 3 && s.data.failed == 1 && s.data.available == 45_000)
        #expect(s.data.payments.count == 4 && s.data.payments[0].customer == "Café ch_1")
        #expect(s.data.payments[3].status == "failed")

        let fine = SnapshotBuilders.stripe(balance: nil, payments: Array(payments.prefix(3)), period: "today",
                                           error: nil, now: now)
        #expect(fine.status == .ok && fine.headline == "All good")

        // Round trip through the wire format: snake_case keys, the store reads back what the shim writes.
        let wire = try SnapshotEncode.encode(s)
        #expect(String(decoding: wire, as: UTF8.self).contains("\"updated_at\":\"2026-10-23T14:28:10Z\""))
        #expect(SnapshotDecode.decode(wire, as: StripeSnapshotData.self) == s)
    }

    @Test func whatsappBuilderCountsUnreadAndPreviews() {
        let ana = WAConversation(id: "521@s.whatsapp.net", name: "Ana", isGroup: false,
                                 messages: [WAMessage(id: "m1", chat: "521@s.whatsapp.net", sender: "me", senderName: "",
                                                      text: "On my way", date: now, fromMe: true)],
                                 unread: 0, lastActivity: now)
        let team = WAConversation(id: "1203@g.us", name: "Acme team", isGroup: true,
                                  messages: [WAMessage(id: "m2", chat: "1203@g.us", sender: "33@s.whatsapp.net",
                                                       senderName: "Luis", text: "look", media: .image,
                                                       date: now, mentionsMe: true)],
                                  unread: 2, lastActivity: now.addingTimeInterval(-300))
        let long = String(repeating: "a", count: 500)
        let bob = WAConversation(id: "522@s.whatsapp.net", name: "Bob", isGroup: false,
                                 messages: [WAMessage(id: "m3", chat: "522@s.whatsapp.net", sender: "522@s.whatsapp.net",
                                                      senderName: "Bob", text: long, date: now)],
                                 unread: 1, lastActivity: now.addingTimeInterval(-600))
        let s = SnapshotBuilders.whatsapp(conversations: [ana, team, bob], linked: true, error: nil, now: now)
        #expect(s.status == .needsYou && s.headline == "3 unread" && s.detail == "3 chats")
        #expect(s.data.unread == 3)
        #expect(s.data.chats[0].preview == "You: On my way" && s.data.chats[0].previewKind == "text")
        #expect(s.data.chats[1].preview == "Luis: Photo · look" && s.data.chats[1].previewKind == "image")
        #expect(s.data.chats[1].isGroup && s.data.chats[1].mentionsMe)
        // One line, not the whole body.
        #expect(s.data.chats[2].preview.count <= SnapshotBuilders.previewLimit)

        let off = SnapshotBuilders.whatsapp(conversations: [], linked: false, error: nil, now: now)
        #expect(off.status == .notSetUp && off.data.chats.isEmpty)
    }

    @Test func whatsappLinkStatesNeverClaimNotLinkedWhileConnecting() {
        func write(_ link: SnapshotBuilders.WALink, failures: Int = 0) -> WidgetSnapshot<WhatsAppSnapshotData>? {
            SnapshotBuilders.whatsapp(conversations: [], link: link, failures: failures, unreachable: "No answer", now: now)
        }
        #expect(write(.connecting) == nil)
        #expect(write(.unreachable, failures: 1) == nil)
        #expect(write(.unreachable, failures: 2)?.status == .failed)
        #expect(write(.unreachable, failures: 2)?.error == "No answer")
        #expect(write(.failed("Refused"))?.status == .failed)
        #expect(write(.needsQR)?.status == .notSetUp && write(.needsQR)?.headline == "Not linked")
        #expect(write(.linked)?.status == .ok)
    }

    @Test func githubBuilderNeedsYouFirst() {
        let mine = GitHubPR(id: "G/k#13", title: "Snapshots", url: "https://github.com/G/k/pull/13", repo: "G/k",
                            number: 13, isDraft: false, ci: .pending, review: .pending)
        let review = GitHubPR(id: "G/m#12", title: "Fix sort", url: "https://github.com/G/m/pull/12", repo: "G/m",
                              number: 12, isDraft: false, ci: .failure, review: .pending)
        let mains = [GitHubRepoCI(repo: "G/m", url: "https://github.com/G/m", branch: "main", ci: .failure),
                     GitHubRepoCI(repo: "G/k", url: "https://github.com/G/k", branch: "main", ci: .success)]
        let pulse = GitHubPulse(login: "G", myPRs: [mine], toReview: [review], mainCI: mains, fetchedAt: now)
        let s = SnapshotBuilders.github(pulse: pulse, activity: nil, stats: GitHubStats(totalRepos: 3, totalStars: 7),
                                        error: nil, now: now)
        #expect(s.status == .needsYou && s.headline == "2 need you" && s.detail == "1 open PR")
        // Review requests first, then failing default branches.
        #expect(s.data.needsYou.map(\.id) == ["G/m#12", "main-G/m"])
        #expect(s.data.needsYou[0].state == "failing" && s.data.needsYou[1].branch == "main")
        #expect(s.data.myPRs[0].state == "running" && s.data.myPRs[0].number == 13)
        #expect(s.data.mains.map(\.state) == ["failing", "passing"] && s.data.mains[0].number == nil)
        #expect(s.data.stars == 7 && s.data.activity.isEmpty)

        let green = GitHubPulse(login: "G", myPRs: [mine], toReview: [], mainCI: [mains[1]], fetchedAt: now)
        let ok = SnapshotBuilders.github(pulse: green, activity: nil, stats: nil, error: nil, now: now)
        #expect(ok.status == .ok && ok.headline == "All green")
    }

    @Test func vercelBuilderOneRowPerProjectNewestFirst() {
        let deployments = [
            VercelDeployment(id: "d3", projectName: "landing", url: "landing-x.vercel.app", state: "READY",
                             createdAt: now.addingTimeInterval(-60), commitMessage: "Copy\nmore", branch: "main"),
            VercelDeployment(id: "d2", projectName: "menuly", url: "", state: "READY",
                             createdAt: now.addingTimeInterval(-600), commitMessage: nil, branch: "feat/x"),
            VercelDeployment(id: "d1", projectName: "landing", url: "landing-y.vercel.app", state: "ERROR",
                             createdAt: now.addingTimeInterval(-3600), commitMessage: "Old", branch: "main"),
        ]
        let s = SnapshotBuilders.vercel(deployments: deployments, error: nil, now: now)
        #expect(s.data.projects.map(\.name) == ["landing", "menuly"])
        #expect(s.data.projects[0].state == "ready" && s.data.projects[0].commit == "Copy")
        #expect(s.data.projects[0].url == "https://landing-x.vercel.app" && s.data.projects[0].isProduction)
        #expect(s.data.projects[1].url == nil && !s.data.projects[1].isProduction)
        // The older failure was replaced by a good deployment: nothing needs you.
        #expect(s.status == .ok && s.headline == "All live" && s.detail == "2 projects")

        let broken = SnapshotBuilders.vercel(deployments: [deployments[2], deployments[1]], error: nil, now: now)
        #expect(broken.status == .needsYou && broken.headline == "1 failed")
        #expect(broken.data.projects[0].name == "landing")   // failures rise to the top
    }

    @Test func builderWithErrorKeepsDataAndFails() {
        let deployments = [VercelDeployment(id: "d1", projectName: "menuly", url: "", state: "READY",
                                            createdAt: now, commitMessage: nil, branch: "main")]
        let s = SnapshotBuilders.vercel(deployments: deployments, error: "Vercel refused the token", now: now)
        #expect(s.status == .failed && s.error == "Vercel refused the token")
        #expect(s.data.projects.count == 1 && s.headline == "Couldn't refresh")

        let stripe = SnapshotBuilders.stripe(balance: nil, payments: [payment("ch_1", 100, "failed")], period: "today",
                                             error: "Offline", now: now)
        #expect(stripe.status == .failed && stripe.data.failed == 1)

        let none = SnapshotBuilders.notSetUp(.github, now: now)
        #expect(none.status == .notSetUp && none.headline == "Not set up" && none.updatedAt == now)
    }
}
