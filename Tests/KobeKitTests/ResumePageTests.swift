import Foundation
import Testing
@testable import KobeKit

struct ResumePageTests {
    let folded = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func reopensOnTheLastPageWithinTheWindow() {
        var resume = ResumePage()
        resume.folded(on: .notes, at: folded)
        #expect(resume.page(now: folded.addingTimeInterval(4 * 60), minutes: 5) == .notes)
        #expect(resume.page(now: folded.addingTimeInterval(5 * 60 + 1), minutes: 5) == nil)
        // Off.
        #expect(resume.page(now: folded.addingTimeInterval(10), minutes: 0) == nil)
    }

    @Test func homeAndNonPagesClearIt() {
        var resume = ResumePage()
        resume.folded(on: .notes, at: folded)
        resume.folded(on: nil, at: folded.addingTimeInterval(60))
        #expect(resume.page(now: folded.addingTimeInterval(61), minutes: 5) == nil)
        resume.folded(on: .now, at: folded)
        #expect(resume.page(now: folded.addingTimeInterval(1), minutes: 5) == nil)
    }

    @Test func minuteChoices() {
        #expect(ResumePage.choices == [0, 2, 5, 10, 15, 30])
    }
}
