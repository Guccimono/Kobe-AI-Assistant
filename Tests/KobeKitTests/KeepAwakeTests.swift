import Foundation
import Synchronization
import Testing
@testable import KobeKit

final class FakePower: PowerAssertion {
    let log = Mutex<[String]>([])
    let refuse: Bool
    init(refuse: Bool = false) { self.refuse = refuse }
    func create(allowDisplaySleep: Bool, reason: String) -> UInt32? {
        if refuse { return nil }
        log.withLock { $0.append("create \(allowDisplaySleep ? "system" : "display")") }
        return 7
    }
    func release(_ id: UInt32) { log.withLock { $0.append("release \(id)") } }
}

@MainActor
struct KeepAwakeTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_000_000) }

    @Test func timedRunCountsDownAndEnds() {
        let power = FakePower(), clock = Clock()
        let awake = KeepAwake(power: power, now: { clock.now })
        #expect(awake.activate(minutes: 90, allowDisplaySleep: false))
        #expect(awake.statusText == "Awake for 1 h 30 min more")
        #expect(awake.shortText == "1:30")
        clock.now += 61 * 60
        #expect(awake.statusText == "Awake for 29 min more")
        #expect(awake.shortText == "29m")
        clock.now += 30 * 60
        awake.checkExpiry()
        #expect(!awake.isActive)
        #expect(power.log.withLock { $0 } == ["create display", "release 7"])
    }

    @Test func indefiniteUntilTurnedOff() {
        let power = FakePower()
        let awake = KeepAwake(power: power)
        awake.activate(minutes: 0, allowDisplaySleep: true)
        #expect(awake.endsAt == nil)
        #expect(awake.statusText == "Awake until you turn it off")
        #expect(awake.shortText == "∞")
        awake.checkExpiry()
        #expect(awake.isActive)
        awake.deactivate()
        #expect(awake.statusText == "Keep awake is off")
        #expect(power.log.withLock { $0 } == ["create system", "release 7"])
    }

    @Test func switchingDisplaySleepKeepsTheTimeLeft() {
        let power = FakePower(), clock = Clock()
        let awake = KeepAwake(power: power, now: { clock.now })
        awake.activate(minutes: 30, allowDisplaySleep: false)
        clock.now += 10 * 60
        awake.setAllowDisplaySleep(true)
        #expect(awake.allowDisplaySleep)
        #expect(awake.statusText == "Awake for 20 min more")
        #expect(power.log.withLock { $0 } == ["create display", "release 7", "create system"])
    }

    @Test func restartingReleasesTheOldAssertionAndRefusalIsReported() {
        let power = FakePower()
        let awake = KeepAwake(power: power)
        awake.activate(minutes: 30, allowDisplaySleep: false)
        awake.activate(minutes: 60, allowDisplaySleep: false)
        #expect(power.log.withLock { $0 } == ["create display", "release 7", "create display"])
        let refused = KeepAwake(power: FakePower(refuse: true))
        #expect(!refused.activate(minutes: 30, allowDisplaySleep: false))
        #expect(!refused.isActive)
    }

    @Test func labels() {
        #expect(KeepAwake.choices.map(KeepAwake.label) == ["30 min", "1 h", "2 h", "Until I turn it off"])
    }
}
