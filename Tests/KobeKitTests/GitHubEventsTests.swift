import Foundation
import Testing
@testable import KobeKit

// GitHubPulse.events(old:new:), the rules, and the one ServiceEvent Kobe reports per poll.

@Test func firstLoadRaisesNothing() {
    let new = ghPulse(myPRs: [ghPR("a/b#1", ci: .failure, sha: "1")], toReview: [ghPR("c/d#2")],
                    mainCI: [ghRepo("a/b", ci: .failure, sha: "m")])
    #expect(GitHubPulse.events(old: nil, new: new).isEmpty)
}

@Test func nothingChangedRaisesNothing() {
    let p = ghPulse(myPRs: [ghPR("a/b#1", ci: .failure, sha: "1")], toReview: [ghPR("c/d#2")],
                  mainCI: [ghRepo("a/b", ci: .failure, sha: "m")])
    #expect(GitHubPulse.events(old: p, new: p).isEmpty)
}

@Test func sameCommitTurningRedIsCIFailed() {
    for before in [CIState.pending, .success, .unknown] {
        let old = ghPulse(myPRs: [ghPR("a/b#1", ci: before, sha: "1")])
        let new = ghPulse(myPRs: [ghPR("a/b#1", ci: .failure, sha: "1")])
        #expect(GitHubPulse.events(old: old, new: new) == [.ciFailed(prId: "a/b#1")])
    }
}

@Test func sameCommitPendingToSuccessIsCIPassed() {
    let old = ghPulse(myPRs: [ghPR("a/b#1", ci: .pending, sha: "1")])
    let new = ghPulse(myPRs: [ghPR("a/b#1", ci: .success, sha: "1")])
    #expect(GitHubPulse.events(old: old, new: new) == [.ciPassed(prId: "a/b#1")])
}

@Test func sameCommitOtherTransitionsAreQuiet() {
    let cases: [(CIState, CIState)] = [(.unknown, .success), (.failure, .success), (.success, .pending),
                                       (.failure, .pending), (.pending, .unknown), (.success, .success)]
    for (before, after) in cases {
        let old = ghPulse(myPRs: [ghPR("a/b#1", ci: before, sha: "1")])
        let new = ghPulse(myPRs: [ghPR("a/b#1", ci: after, sha: "1")])
        #expect(GitHubPulse.events(old: old, new: new).isEmpty, "\(before) → \(after)")
    }
}

@Test func bothShasMissingCountAsTheSameCommit() {
    let old = ghPulse(myPRs: [ghPR("a/b#1", ci: .pending)])
    let new = ghPulse(myPRs: [ghPR("a/b#1", ci: .success)])
    #expect(GitHubPulse.events(old: old, new: new) == [.ciPassed(prId: "a/b#1")])
    // Already green with no SHA on either side: same commit, quiet.
    let quiet = ghPulse(myPRs: [ghPR("a/b#1", ci: .success)])
    #expect(GitHubPulse.events(old: quiet, new: quiet).isEmpty)
}

@Test func newCommitAlreadyFinishedFiresAtOnce() {
    let old = ghPulse(myPRs: [ghPR("a/b#1", ci: .success, sha: "1"), ghPR("a/b#2", ci: .failure, sha: "2")])
    let new = ghPulse(myPRs: [ghPR("a/b#1", ci: .success, sha: "1b"), ghPR("a/b#2", ci: .failure, sha: "2b")])
    #expect(GitHubPulse.events(old: old, new: new) == [.ciPassed(prId: "a/b#1"), .ciFailed(prId: "a/b#2")])
}

@Test func newCommitStillRunningWaitsForTheNextPoll() {
    let old = ghPulse(myPRs: [ghPR("a/b#1", ci: .failure, sha: "1")])
    let running = ghPulse(myPRs: [ghPR("a/b#1", ci: .pending, sha: "2")])
    #expect(GitHubPulse.events(old: old, new: running).isEmpty)
    let done = ghPulse(myPRs: [ghPR("a/b#1", ci: .success, sha: "2")])
    #expect(GitHubPulse.events(old: running, new: done) == [.ciPassed(prId: "a/b#1")])
    let unknown = ghPulse(myPRs: [ghPR("a/b#1", ci: .unknown, sha: "3")])
    #expect(GitHubPulse.events(old: done, new: unknown).isEmpty)
}

@Test func newPRAlreadyFinishedFiresAtOnce() {
    let old = ghPulse()
    let new = ghPulse(myPRs: [ghPR("a/b#1", ci: .success, sha: "1"), ghPR("a/b#2", ci: .failure, sha: "2"),
                            ghPR("a/b#3", ci: .pending, sha: "3")])
    #expect(GitHubPulse.events(old: old, new: new) == [.ciPassed(prId: "a/b#1"), .ciFailed(prId: "a/b#2")])
}

@Test func closedPRsRaiseNothing() {
    let old = ghPulse(myPRs: [ghPR("a/b#1", ci: .failure, sha: "1")])
    #expect(GitHubPulse.events(old: old, new: ghPulse()).isEmpty)
}

@Test func defaultBranchOnlyAlertsOnANewFailure() {
    let green = ghPulse(mainCI: [ghRepo("a/b", ci: .success, sha: "1")])
    let red = ghPulse(mainCI: [ghRepo("a/b", ci: .failure, sha: "1")])
    #expect(GitHubPulse.events(old: green, new: red) == [.mainFailed(repo: "a/b")])
    // Still red: quiet. Back to green: quiet (no green alert for the default branch).
    #expect(GitHubPulse.events(old: red, new: red).isEmpty)
    #expect(GitHubPulse.events(old: red, new: green).isEmpty)
    // Pending → success on the same commit: quiet.
    let running = ghPulse(mainCI: [ghRepo("a/b", ci: .pending, sha: "1")])
    #expect(GitHubPulse.events(old: running, new: green).isEmpty)
}

@Test func defaultBranchNewCommitOrRepo() {
    let red = ghPulse(mainCI: [ghRepo("a/b", ci: .failure, sha: "1")])
    let redAgain = ghPulse(mainCI: [ghRepo("a/b", ci: .failure, sha: "2")])
    #expect(GitHubPulse.events(old: red, new: redAgain) == [.mainFailed(repo: "a/b")])
    let greenNew = ghPulse(mainCI: [ghRepo("a/b", ci: .success, sha: "3")])
    #expect(GitHubPulse.events(old: red, new: greenNew).isEmpty)
    let newRepo = ghPulse(mainCI: [ghRepo("a/b", ci: .failure, sha: "1"), ghRepo("c/d", ci: .failure, sha: "x")])
    #expect(GitHubPulse.events(old: red, new: newRepo) == [.mainFailed(repo: "c/d")])
}

@Test func newReviewRequestsAreReported() {
    let old = ghPulse(toReview: [ghPR("c/d#2")])
    let new = ghPulse(toReview: [ghPR("c/d#2"), ghPR("e/f#3")])
    #expect(GitHubPulse.events(old: old, new: new) == [.reviewRequested(prId: "e/f#3")])
    #expect(GitHubPulse.events(old: new, new: old).isEmpty)
}

@Test func eventsKeepPROrderThenBranchesThenReviews() {
    let old = ghPulse(myPRs: [ghPR("a/b#1", ci: .pending, sha: "1")], mainCI: [ghRepo("a/b", ci: .success, sha: "m")])
    let new = ghPulse(myPRs: [ghPR("a/b#1", ci: .success, sha: "1")], toReview: [ghPR("c/d#2")],
                    mainCI: [ghRepo("a/b", ci: .failure, sha: "m")])
    #expect(GitHubPulse.events(old: old, new: new)
            == [.ciPassed(prId: "a/b#1"), .mainFailed(repo: "a/b"), .reviewRequested(prId: "c/d#2")])
}

// MARK: - The reported event

@Test func noEventsReportNothing() {
    #expect(GitHubPulse.serviceEvent(for: [], in: ghPulse()) == nil)
}

@Test func errorsOutrankReviewsAndPasses() {
    let p = ghPulse(myPRs: [ghPR("o/app#4"), ghPR("o/app#5")], mainCI: [ghRepo("o/site", branch: "trunk")])
    let failed = GitHubPulse.serviceEvent(for: [.ciPassed(prId: "o/app#5"), .reviewRequested(prId: "x/y#1"),
                                                .ciFailed(prId: "o/app#4")], in: p)
    #expect(failed == ServiceEvent(pill: "github", kind: .error, detail: "Checks failing on app#4", sound: .error))
    let main = GitHubPulse.serviceEvent(for: [.reviewRequested(prId: "x/y#1"), .mainFailed(repo: "o/site")], in: p)
    #expect(main == ServiceEvent(pill: "github", kind: .error, detail: "CI failing on site · trunk", sound: .error))
}

@Test func firstErrorOfTheSameRankWins() {
    let p = ghPulse(mainCI: [ghRepo("o/site")])
    let event = GitHubPulse.serviceEvent(for: [.mainFailed(repo: "o/site"), .ciFailed(prId: "o/app#4")], in: p)
    #expect(event?.detail == "CI failing on site · main")
}

@Test func reviewRequestOutranksAPass() {
    let event = GitHubPulse.serviceEvent(for: [.ciPassed(prId: "o/app#5"), .reviewRequested(prId: "x/y#1")], in: ghPulse())
    #expect(event == ServiceEvent(pill: "github", kind: .attention, detail: "Review requested: y#1", sound: .question))
}

@Test func aPassAloneIsFinished() {
    let event = GitHubPulse.serviceEvent(for: [.ciPassed(prId: "o/app#5")], in: ghPulse())
    #expect(event == ServiceEvent(pill: "github", kind: .finished, detail: "Checks passed on app#5", sound: .finish))
}

@Test func mainFailedForAnUnknownRepoStillNamesIt() {
    let event = GitHubPulse.serviceEvent(for: [.mainFailed(repo: "o/gone")], in: ghPulse())
    #expect(event?.detail == "CI failing on gone")
}
