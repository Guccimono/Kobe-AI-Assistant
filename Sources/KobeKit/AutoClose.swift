import Foundation

/// What the island is showing, for the auto-close rule.
public enum IslandOverlayKind: Sendable {
    case finished, notification, permission, question, quickAsk, none
}

/// A finished or notification view folds after the chosen 10/15/30 s, unless the pointer is over it or it's pinned.
/// Anything that waits for an answer never folds by itself.
public enum AutoClose {
    public static func shouldFold(overlay: IslandOverlayKind, shownFor: TimeInterval, setting: Int, hovering: Bool, pinned: Bool) -> Bool {
        switch overlay {
        case .finished, .notification:
            return !hovering && !pinned && shownFor >= TimeInterval(setting)
        case .permission, .question, .quickAsk, .none:
            return false
        }
    }
}
