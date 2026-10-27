import Foundation

/// What a key does on the Agenda page: in the event detail ← and Esc go back to the day; on the day ↑↓ pick,
/// Return opens, ← → change month.
public enum AgendaMove: Equatable, Sendable {
    case back, month(Int), none, open, select(PageSelection.Direction)
}

public enum AgendaNavigation {
    public static func move(_ key: PageKey, detailOpen: Bool) -> AgendaMove {
        if detailOpen {
            switch key {
            case .left, .escape: return .back
            default: return .none
            }
        }
        switch key {
        case .up: return .select(.up)
        case .down: return .select(.down)
        case .enter: return .open
        case .left: return .month(-1)
        case .right: return .month(1)
        case .escape, .refresh, .search, .hide: return .none
        }
    }
}
