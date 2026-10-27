import Foundation
import Testing
@testable import KobeKit

struct AllowLockTests {
    @Test func lockedUntilACardOnScreenSaysItsEndWasSeen() {
        var lock = AllowLock()
        // Nothing on screen: a hotkey can never allow what isn't shown.
        #expect(lock.locked)
        let card = UUID()
        lock.report(card, locked: true)
        #expect(lock.locked)
        lock.report(card, locked: false)
        #expect(!lock.locked)
        // The card goes: locked again, never left unlocked.
        lock.report(card, locked: nil)
        #expect(lock.locked)
    }

    @Test func anyCardStillLockedKeepsItLocked() {
        var lock = AllowLock()
        let old = UUID(), new = UUID()
        lock.report(old, locked: false)
        lock.report(new, locked: true)
        #expect(lock.locked)
        lock.report(old, locked: nil)
        #expect(lock.locked)
        lock.report(new, locked: false)
        #expect(!lock.locked)
    }
}
