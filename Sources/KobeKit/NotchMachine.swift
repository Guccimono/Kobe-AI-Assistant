import Foundation

/// The notch: closed, the wings (a wide band beside the notch) and open. Hover (when "Open on hover" is on) spreads
/// it into the wings; a click opens it fully; leaving folds it after a short delay. A notification (Claude finished,
/// a reply, something to approve) also shows the wings, and they stay until it's done. Something waiting for an
/// answer never disappears: leaving or closing the open notch falls back to the band until it's answered.
public enum NotchPhase: Equatable, Sendable, CaseIterable {
    case resting
    /// The wings: the wide band beside the notch, on hover or for a notification.
    case compact
    case expanded
}

public struct NotchContext: Equatable, Sendable {
    public var pinned: Bool
    public var hovering: Bool
    /// An approval or a Claude Code question is waiting for an answer.
    public var approval: Bool
    /// The wings show a notification (they stay until it's done, even when the pointer leaves).
    public var notice: Bool

    public init(pinned: Bool = false, hovering: Bool = false, approval: Bool = false, notice: Bool = false) {
        self.pinned = pinned
        self.hovering = hovering
        self.approval = approval
        self.notice = notice
    }
}

public enum NotchEvent: Equatable, Sendable {
    case hoverEntered
    case hoverLeft
    /// The fold delay ran out.
    case foldTimerFired
    /// A click on the notch or the band.
    case clicked
    /// Open fully from code: a hotkey, the menu bar, a drop, Settings.
    case openRequested
    /// Esc, click outside, the close button, a notification that's done.
    case closeRequested
    /// Something to show as the wide band.
    case notified
    /// Pinned or "waiting for an answer" changed.
    case contextChanged
}

public struct NotchTransition: Equatable, Sendable {
    public let phase: NotchPhase
    /// Start the fold delay (cancelling any running one).
    public let scheduleFold: Bool
    /// Cancel a running fold delay.
    public let cancelFold: Bool
}

public enum NotchMachine {
    public static let foldDelay: TimeInterval = 0.5

    public static func reduce(_ phase: NotchPhase, _ event: NotchEvent, _ context: NotchContext) -> NotchTransition {
        func stay() -> NotchTransition { NotchTransition(phase: phase, scheduleFold: false, cancelFold: false) }
        func go(_ p: NotchPhase) -> NotchTransition { NotchTransition(phase: p, scheduleFold: false, cancelFold: true) }
        func fold() -> NotchTransition { NotchTransition(phase: phase, scheduleFold: true, cancelFold: false) }
        /// Where the open notch goes when it closes: the band while something waits, else closed.
        var settled: NotchPhase { context.approval ? .compact : .resting }

        switch (phase, event) {
        case (.resting, .clicked), (.resting, .openRequested): return go(.expanded)
        case (.resting, .hoverEntered), (.resting, .notified): return go(.compact)
        case (.resting, _): return stay()

        case (.compact, .clicked), (.compact, .openRequested): return go(.expanded)
        case (.compact, .hoverEntered): return NotchTransition(phase: .compact, scheduleFold: false, cancelFold: true)
        case (.compact, .hoverLeft): return context.approval || context.notice ? stay() : fold()
        case (.compact, .foldTimerFired): return context.approval || context.notice || context.hovering ? stay() : go(.resting)
        case (.compact, .closeRequested): return context.approval ? stay() : go(.resting)
        case (.compact, _): return stay()

        case (.expanded, .hoverEntered): return go(.expanded)
        case (.expanded, .hoverLeft): return context.pinned ? stay() : fold()
        case (.expanded, .foldTimerFired): return (context.pinned || context.hovering) ? stay() : go(settled)
        case (.expanded, .closeRequested): return go(settled)
        case (.expanded, .clicked), (.expanded, .openRequested), (.expanded, .notified), (.expanded, .contextChanged): return stay()
        }
    }
}
