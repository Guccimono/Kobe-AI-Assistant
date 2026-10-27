import Foundation
import Testing
@testable import KobeKit

// MARK: - States

@Test func ciStateMapsGitHubRollups() {
    #expect(CIState(rawGitHub: "PENDING") == .pending)
    #expect(CIState(rawGitHub: "expected") == .pending)
    #expect(CIState(rawGitHub: "SUCCESS") == .success)
    #expect(CIState(rawGitHub: "ERROR") == .failure)
    #expect(CIState(rawGitHub: "FAILURE") == .failure)
    #expect(CIState(rawGitHub: "SKIPPED") == .unknown)
    #expect(CIState(rawGitHub: nil) == .unknown)
}

@Test func reviewStateMapsReviewDecisions() {
    #expect(ReviewState(rawGitHub: "APPROVED") == .approved)
    #expect(ReviewState(rawGitHub: "CHANGES_REQUESTED") == .changesRequested)
    #expect(ReviewState(rawGitHub: "REVIEW_REQUIRED") == .pending)
    #expect(ReviewState(rawGitHub: "other") == .unknown)
    #expect(ReviewState(rawGitHub: nil) == .unknown)
}

@Test func worstCIOrdersFailurePendingSuccess() {
    #expect(CIState.worst([.success, .pending, .failure]) == .failure)
    #expect(CIState.worst([.success, .pending, .unknown]) == .pending)
    #expect(CIState.worst([.unknown, .success]) == .success)
    #expect(CIState.worst([.unknown]) == .unknown)
    #expect(CIState.worst([]) == .unknown)
}

// MARK: - Pulse parsing

@Test func pulseParsesPRsReposAndReviews() throws {
    let pulse = try #require(GitHubPulse.parse(StubURLProtocol.fixture("github_pulse.json")))
    #expect(pulse.login == "samrivera")

    // Duplicates and nodes without a number are skipped.
    #expect(pulse.myPRs.map(\.id) == ["acme/web#12", "acme/docs#3", "acme/api#7"])
    let first = pulse.myPRs[0]
    #expect(first.title == "Add menu export")
    #expect(first.url == "https://github.com/acme/web/pull/12")
    #expect(first.repo == "acme/web")
    #expect(first.number == 12)
    #expect(!first.isDraft)
    #expect(first.ci == .failure)
    #expect(first.review == .approved)
    #expect(first.headSha == "aaa111")
    #expect(pulse.myPRs[1].isDraft)
    #expect(pulse.myPRs[1].ci == .pending)
    #expect(pulse.myPRs[1].review == .pending)
    #expect(pulse.myPRs[2].ci == .unknown)
    #expect(pulse.myPRs[2].review == .changesRequested)
    #expect(pulse.myPRs[2].headSha == "ccc333")

    // Archived repos and repos without a default branch are skipped.
    #expect(pulse.mainCI.map(\.repo) == ["acme/web", "acme/api", "octo-org/site"])
    #expect(pulse.mainCI[0].branch == "main")
    #expect(pulse.mainCI[0].ci == .success)
    #expect(pulse.mainCI[0].headSha == "m1")
    #expect(pulse.mainCI[0].url == "https://github.com/acme/web")
    #expect(pulse.mainCI[1].branch == "trunk")
    #expect(pulse.mainCI[1].ci == .failure)
    #expect(pulse.mainCI[2].ci == .unknown)
    #expect(pulse.mainCI[2].headSha == "s1")

    // Review requests: deduped, CI unknown, review pending.
    #expect(pulse.toReview.map(\.id) == ["x/y#9"])
    #expect(pulse.toReview[0].ci == .unknown)
    #expect(pulse.toReview[0].review == .pending)
    #expect(pulse.toReview[0].headSha == nil)

    #expect(pulse.hasPending)
}

@Test func pulseToleratesPartialErrors() throws {
    let pulse = try #require(GitHubPulse.parse(StubURLProtocol.fixture("github_pulse_partial.json")))
    #expect(pulse.login == "samrivera")
    #expect(pulse.myPRs.isEmpty && pulse.toReview.isEmpty && pulse.mainCI.isEmpty)
    #expect(!pulse.hasPending)
}

@Test func pulseWithoutDataIsNil() {
    #expect(GitHubPulse.parse(StubURLProtocol.fixture("github_graphql_errors.json")) == nil)
    #expect(GitHubPulse.parse(Data("not json".utf8)) == nil)
}

@Test func hasPendingLooksAtPRsAndDefaultBranches() {
    #expect(!ghPulse().hasPending)
    #expect(ghPulse(myPRs: [ghPR("a/b#1", ci: .pending)]).hasPending)
    #expect(ghPulse(mainCI: [ghRepo("a/b", ci: .pending)]).hasPending)
    #expect(!ghPulse(myPRs: [ghPR("a/b#1", ci: .failure)], toReview: [ghPR("c/d#2", ci: .pending)]).hasPending)
}

@Test func stalenessFollowsMaxAge() {
    let now = Date()
    #expect(GitHubPulse.isStale(fetchedAt: nil, now: now, maxAge: 60))
    #expect(!GitHubPulse.isStale(fetchedAt: now.addingTimeInterval(-30), now: now, maxAge: 60))
    #expect(!GitHubPulse.isStale(fetchedAt: now.addingTimeInterval(-60), now: now, maxAge: 60))
    #expect(GitHubPulse.isStale(fetchedAt: now.addingTimeInterval(-61), now: now, maxAge: 60))
}

// MARK: - Activity

@Test func activityParsesTheContributionCalendar() throws {
    let activity = try #require(GitHubActivity.parse(StubURLProtocol.fixture("github_activity.json")))
    #expect(activity.total == 1234)
    // The empty week is dropped; the malformed day is skipped.
    #expect(activity.weeks.count == 3)
    #expect(activity.weeks[0].map(\.level) == [0, 1, 1])
    #expect(activity.weeks[1].map(\.level) == [2, 3, 4, 0, 0, 1, 0])
    #expect(activity.weeks[1][0] == ContributionDay(date: "2026-10-11", count: 5, level: 2, weekday: 0))
    #expect(activity.weeks[2] == [ContributionDay(date: "2026-10-18", count: 4, level: 2, weekday: 0)])
}

@Test func activityWithoutCalendarIsNil() {
    #expect(GitHubActivity.parse(StubURLProtocol.fixture("github_graphql_errors.json")) == nil)
    #expect(GitHubActivity.parse(StubURLProtocol.fixture("github_pulse.json")) == nil)
}

@Test func activityLastWeeksAndDays() throws {
    let activity = try #require(GitHubActivity.parse(StubURLProtocol.fixture("github_activity.json")))
    #expect(activity.lastWeeks(0).isEmpty)
    #expect(activity.lastWeeks(2).count == 2)
    #expect(activity.lastWeeks(2)[1][0].date == "2026-10-18")
    #expect(activity.lastWeeks(99).count == 3)
    #expect(activity.lastDays(0).isEmpty)
    #expect(activity.lastDays(3).map(\.date) == ["2026-10-16", "2026-10-17", "2026-10-18"])
    #expect(activity.lastDays(100).count == 11)
}

@Test func activityGridFitsAsManyWeeksAsTheWidthAllows() {
    // 202 pt, 7 pt squares, 1.5 pt gaps → 23 weeks.
    #expect(GitHubActivity.weeksThatFit(width: 202, square: 7, spacing: 1.5) == 23)
    #expect(GitHubActivity.weeksThatFit(width: 5000, square: 7, spacing: 1.5) == 53)
    #expect(GitHubActivity.weeksThatFit(width: 0, square: 7, spacing: 1.5) == 0)
    #expect(GitHubActivity.weeksThatFit(width: 7, square: 7, spacing: 1.5) == 1)
}

// MARK: - Formatting

@Test func countsShortenFromAThousand() {
    #expect(GitHubFormat.count(0) == "0")
    #expect(GitHubFormat.count(999) == "999")
    #expect(GitHubFormat.count(1000) == "1.0k")
    #expect(GitHubFormat.count(1234) == "1.2k")
    #expect(GitHubFormat.count(15_600) == "15.6k")
}

@Test func activityLabels() {
    #expect(GitHubFormat.dayLabel("2026-10-05") == "Oct 5")
    #expect(GitHubFormat.dayLabel("2026-01-31") == "Jan 31")
    #expect(GitHubFormat.dayLabel("bad") == "bad")
    #expect(GitHubFormat.dayLabel("2026-13-01") == "2026-13-01")
    #expect(GitHubFormat.contributions(0) == "No contributions")
    #expect(GitHubFormat.contributions(1) == "1 contribution")
    #expect(GitHubFormat.contributions(12) == "12 contributions")
    let day = ContributionDay(date: "2026-10-05", count: 3, level: 1, weekday: 1)
    #expect(GitHubFormat.hover(day) == "Oct 5 · 3 contributions")
    #expect(GitHubFormat.total(1234) == "1,234")
    #expect(GitHubFormat.activityHeader(total: 1234, repos: 17) == "1,234 past year · 17 repos")
    #expect(GitHubFormat.activityHeader(total: 5, repos: nil) == "5 past year")
}

@Test func myPRsValueSummarisesCI() {
    #expect(GitHubFormat.myPRsValue([]) == "0")
    #expect(GitHubFormat.myPRsValue([ghPR("a/b#1", ci: .success), ghPR("a/b#2", ci: .unknown)]) == "2")
    #expect(GitHubFormat.myPRsValue([ghPR("a/b#1", ci: .pending), ghPR("a/b#2", ci: .success)]) == "2 · running")
    #expect(GitHubFormat.myPRsValue([ghPR("a/b#1", ci: .pending), ghPR("a/b#2", ci: .failure), ghPR("a/b#3", ci: .failure)])
            == "3 · 2 failing")
}

@Test func defaultBranchValueSummarisesCI() {
    #expect(GitHubFormat.mainCIValue([]) == "no repos")
    #expect(GitHubFormat.mainCIValue([ghRepo("a/b", ci: .unknown)]) == "unknown")
    #expect(GitHubFormat.mainCIValue([ghRepo("a/b", ci: .success)]) == "all green")
    #expect(GitHubFormat.mainCIValue([ghRepo("a/b", ci: .success), ghRepo("a/c", ci: .pending)]) == "running")
    #expect(GitHubFormat.mainCIValue([ghRepo("a/b", ci: .failure), ghRepo("a/c", ci: .failure), ghRepo("a/d", ci: .pending)])
            == "2 failing")
}

@Test func rowWordsAndShortNames() {
    #expect(GitHubFormat.repoWord(.failure) == "failing")
    #expect(GitHubFormat.repoWord(.pending) == "running")
    #expect(GitHubFormat.repoWord(.success) == "passing")
    #expect(GitHubFormat.repoWord(.unknown) == nil)
    #expect(GitHubFormat.shortRepo("acme/web") == "web")
    #expect(GitHubFormat.shortRepo("solo") == "solo")
    #expect(GitHubFormat.prLabel(ghPR("acme/web#12")) == "web#12")
}

// MARK: - Links

@Test func linksOpenOnlyGitHubDotCom() {
    #expect(GitHubLinks.pr("https://github.com/a/b/pull/1")?.absoluteString == "https://github.com/a/b/pull/1")
    #expect(GitHubLinks.pr("https://evil.example/a/b/pull/1") == nil)
    #expect(GitHubLinks.pr("http://github.com/a/b/pull/1") == nil)
    #expect(GitHubLinks.pr("javascript:alert(1)") == nil)
    #expect(GitHubLinks.actions("https://github.com/a/b")?.absoluteString == "https://github.com/a/b/actions")
    #expect(GitHubLinks.actions("https://github.com/a/b/")?.absoluteString == "https://github.com/a/b/actions")
    #expect(GitHubLinks.actions("https://gitlab.com/a/b") == nil)
    #expect(GitHubLinks.profile("samrivera")?.absoluteString == "https://github.com/samrivera")
    #expect(GitHubLinks.profile("") == nil)
    #expect(GitHubLinks.profile("a/../b") == nil)
    #expect(GitHubLinks.home.absoluteString == "https://github.com")
    #expect(GitHubLinks.pulls.absoluteString == "https://github.com/pulls")
}

// MARK: - Schedule

@Test func pulseCadenceFollowsPendingChecks() {
    #expect(GitHubSchedule.statsFirst == 7)
    #expect(GitHubSchedule.statsEvery == 300)
    #expect(GitHubSchedule.pulseFirst == 10)
    #expect(GitHubSchedule.nextPulse(hasPending: true) == 60)
    #expect(GitHubSchedule.nextPulse(hasPending: false) == 300)
    #expect(GitHubSchedule.activityFirst == 15)
    #expect(GitHubSchedule.activityEvery == 1800)
    #expect(GitHubSchedule.pulseMaxAge == 60)
    #expect(GitHubSchedule.activityMaxAge == 300)
}

// MARK: - Helpers

func ghPR(_ id: String, ci: CIState = .unknown, sha: String? = nil, title: String = "T", draft: Bool = false) -> GitHubPR {
    let parts = id.split(separator: "#")
    let repo = String(parts[0])
    let number = Int(parts[1])!
    return GitHubPR(id: id, title: title, url: "https://github.com/\(repo)/pull/\(number)", repo: repo, number: number,
                    isDraft: draft, ci: ci, review: .unknown, headSha: sha)
}

func ghRepo(_ name: String, ci: CIState = .unknown, sha: String? = nil, branch: String = "main") -> GitHubRepoCI {
    GitHubRepoCI(repo: name, url: "https://github.com/\(name)", branch: branch, ci: ci, headSha: sha)
}

func ghPulse(myPRs: [GitHubPR] = [], toReview: [GitHubPR] = [], mainCI: [GitHubRepoCI] = []) -> GitHubPulse {
    GitHubPulse(login: "me", myPRs: myPRs, toReview: toReview, mainCI: mainCI, fetchedAt: Date())
}
