import Foundation

/// The move from the app's shim to Kobe Agent, one connector at a time: whoever wrote the file last owns it while
/// that file is fresh. The shim steps aside for a fresh agent file and takes over again when it goes stale
/// (age > 3 × schedule), so a stopped agent never leaves a page frozen. A shim without a key never blanks an agent's
/// file with "not set up": the last numbers stay and read as stale.
public enum Handover {
    public static func shimMayWrite(existing: (source: SnapshotSource, updatedAt: Date)?, id: WidgetID,
                                    status: SnapshotStatus, now: Date = .now) -> Bool {
        if status == .notSetUp, existing?.source == .agent { return false }
        return owner(existing: existing, id: id, now: now) == .app
    }

    public static func owner(existing: (source: SnapshotSource, updatedAt: Date)?, id: WidgetID,
                             now: Date = .now) -> SnapshotSource {
        guard let existing, existing.source == .agent else { return .app }
        if case .fresh = SnapshotRules.freshness(updatedAt: existing.updatedAt, schedule: SnapshotRules.schedule(for: id),
                                                 now: now) {
            return .agent
        }
        return .app
    }
}
