import Foundation
import Testing
@testable import KobeKit

/// Closed, the wings (hover or a notification) and open (a click).
struct NotchMachineTests {
    private let idle = NotchContext()

    @Test func threePhases() {
        #expect(NotchPhase.allCases == [.resting, .compact, .expanded])
    }

    @Test func aNotificationShowsTheWideBandNotTheFullNotch() {
        #expect(NotchMachine.reduce(.resting, .notified, idle).phase == .compact)
        #expect(NotchMachine.reduce(.expanded, .notified, idle).phase == .expanded)  // already open: shown inside
    }

    @Test func hoverShowsTheWingsAClickOpens() {
        #expect(NotchMachine.reduce(.resting, .hoverEntered, idle).phase == .compact)
        #expect(NotchMachine.reduce(.compact, .hoverEntered, idle).phase == .compact)
        #expect(NotchMachine.reduce(.resting, .clicked, idle).phase == .expanded)
        #expect(NotchMachine.reduce(.compact, .clicked, idle).phase == .expanded)
    }

    @Test func leavingTheWingsFoldsThemUnlessANotificationShows() {
        let left = NotchMachine.reduce(.compact, .hoverLeft, idle)
        #expect(left.phase == .compact && left.scheduleFold)
        #expect(NotchMachine.reduce(.compact, .foldTimerFired, idle).phase == .resting)
        #expect(NotchMachine.reduce(.compact, .foldTimerFired, NotchContext(hovering: true)).phase == .compact)  // came back
        let notice = NotchContext(notice: true)
        #expect(!NotchMachine.reduce(.compact, .hoverLeft, notice).scheduleFold)
        #expect(NotchMachine.reduce(.compact, .foldTimerFired, notice).phase == .compact)
        #expect(NotchMachine.reduce(.compact, .foldTimerFired, NotchContext(approval: true)).phase == .compact)
    }

    @Test func theWideBandOpensOnClickAndFoldsWhenDone() {
        #expect(NotchMachine.reduce(.compact, .clicked, idle).phase == .expanded)
        #expect(NotchMachine.reduce(.compact, .openRequested, idle).phase == .expanded)
        #expect(NotchMachine.reduce(.compact, .closeRequested, idle).phase == .resting)
        #expect(NotchMachine.reduce(.compact, .contextChanged, idle).phase == .compact)
        #expect(NotchMachine.reduce(.compact, .hoverLeft, NotchContext(notice: true)).phase == .compact)  // stays until done
    }

    @Test func leavingTheOpenNotchWhileSomethingWaitsFallsBackToTheBand() {
        let waiting = NotchContext(approval: true)
        #expect(NotchMachine.reduce(.expanded, .hoverLeft, waiting).scheduleFold)
        #expect(NotchMachine.reduce(.expanded, .foldTimerFired, waiting).phase == .compact)
        #expect(NotchMachine.reduce(.expanded, .closeRequested, waiting).phase == .compact)
        #expect(NotchMachine.reduce(.compact, .closeRequested, waiting).phase == .compact)  // answer it first
    }

    @Test func clickOpensLeavingFolds() {
        #expect(NotchMachine.reduce(.resting, .clicked, idle).phase == .expanded)
        let left = NotchMachine.reduce(.expanded, .hoverLeft, idle)
        #expect(left.phase == .expanded && left.scheduleFold)
        #expect(NotchMachine.reduce(.expanded, .foldTimerFired, idle).phase == .resting)
        #expect(NotchMachine.reduce(.expanded, .foldTimerFired, NotchContext(hovering: true)).phase == .expanded)  // came back
        #expect(NotchMachine.reduce(.expanded, .hoverEntered, idle).cancelFold)
    }

    @Test func onlyThePinHoldsItOpen() {
        #expect(!NotchMachine.reduce(.expanded, .hoverLeft, NotchContext(pinned: true)).scheduleFold)
        #expect(NotchMachine.reduce(.expanded, .closeRequested, NotchContext(pinned: true)).phase == .resting)  // Esc unpins
    }

    @Test func nothingOpensItByItselfExceptARequest() {
        #expect(NotchMachine.reduce(.resting, .contextChanged, idle).phase == .resting)
        #expect(NotchMachine.reduce(.resting, .hoverLeft, idle).phase == .resting)
        #expect(NotchMachine.reduce(.resting, .openRequested, idle).phase == .expanded)
    }
}
