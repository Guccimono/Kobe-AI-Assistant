import Foundation
import IOKit.pwr_mgt
import Observation

/// A sleep-preventing power assertion. Live: IOKit. Tests: a fake.
public protocol PowerAssertion: Sendable {
    /// Returns an id, or nil when macOS refused.
    func create(allowDisplaySleep: Bool, reason: String) -> UInt32?
    func release(_ id: UInt32)
}

/// IOPMAssertion: no fake keypresses, no polling. With `allowDisplaySleep` the screen may sleep, the Mac doesn't.
public struct IOKitPowerAssertion: PowerAssertion {
    public init() {}

    public func create(allowDisplaySleep: Bool, reason: String) -> UInt32? {
        let type = allowDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess
        else { return nil }
        return id
    }

    public func release(_ id: UInt32) { IOPMAssertionRelease(id) }
}

/// Keeps the Mac awake for a while or until turned off. Ported from the Mocha notch app.
@MainActor
@Observable
public final class KeepAwake {
    /// Menu choices in minutes; 0 means "until I turn it off".
    public static let choices = [30, 60, 120, 0]

    public private(set) var isActive = false
    /// Nil while active means indefinitely.
    public private(set) var endsAt: Date?
    public private(set) var allowDisplaySleep = false

    private let power: any PowerAssertion
    private let now: () -> Date
    private var assertion: UInt32?
    private var expiry: Timer?

    public init(power: any PowerAssertion = IOKitPowerAssertion(), now: @escaping () -> Date = { Date() }) {
        self.power = power
        self.now = now
    }

    public static func label(minutes: Int) -> String {
        switch minutes {
        case 0: "Until I turn it off"
        case ..<60: "\(minutes) min"
        default: "\(minutes / 60) h"
        }
    }

    /// Starts (or restarts) keeping awake. `minutes` 0 is indefinite.
    @discardableResult
    public func activate(minutes: Int, allowDisplaySleep: Bool) -> Bool {
        deactivate()
        guard let id = power.create(allowDisplaySleep: allowDisplaySleep, reason: "Kobe is keeping your Mac awake") else { return false }
        assertion = id
        isActive = true
        self.allowDisplaySleep = allowDisplaySleep
        if minutes > 0 {
            let seconds = TimeInterval(minutes * 60)
            endsAt = now().addingTimeInterval(seconds)
            expiry = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivate() }
            }
            expiry?.tolerance = 5
        }
        return true
    }

    public func deactivate() {
        expiry?.invalidate()
        expiry = nil
        endsAt = nil
        if let assertion { power.release(assertion) }
        assertion = nil
        isActive = false
    }

    /// Re-creates the assertion when "allow display sleep" changes, keeping the time left.
    public func setAllowDisplaySleep(_ allow: Bool) {
        guard isActive, allow != allowDisplaySleep else { return }
        let left = endsAt.map { max(1, Int(($0.timeIntervalSince(now()) / 60).rounded(.up))) } ?? 0
        activate(minutes: left, allowDisplaySleep: allow)
    }

    /// Called by a timer or on wake: ends it when the time is up (timers can be late after sleep).
    public func checkExpiry() {
        if let endsAt, now() >= endsAt { deactivate() }
    }

    /// "Awake for 1 h 20 min more", "Awake until you turn it off", "Keep awake is off".
    public var statusText: String {
        guard isActive else { return "Keep awake is off" }
        guard let endsAt else { return "Awake until you turn it off" }
        return "Awake for \(Self.remaining(endsAt.timeIntervalSince(now()))) more"
    }

    /// Short form for the notch wing: "1:20", "∞".
    public var shortText: String {
        guard isActive else { return "" }
        guard let endsAt else { return "∞" }
        let minutes = max(1, Int((endsAt.timeIntervalSince(now()) / 60).rounded(.up)))
        return minutes >= 60 ? "\(minutes / 60):\(String(format: "%02d", minutes % 60))" : "\(minutes)m"
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
