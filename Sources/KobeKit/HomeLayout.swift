/// Home's folded chat (⌘\) must never hide something waiting in it: an approval, a drop's message or refused
/// files, a reply the user was brought Home for, or a request for the caret. Pure, so the rule is tested.
/// How Home splits: both panes, Now folded to a rail while writing, or the chat folded while reading.
public enum HomeMode: String, Sendable, Equatable {
    case split, writing, reading
}

/// What Home opens on. "Writing first" opens split when something waits for the user.
public enum HomeStart: String, CaseIterable, Sendable, Codable {
    case writing, split, now

    public var label: String {
        switch self {
        case .writing: "Writing first"
        case .split: "Split"
        case .now: "Now first"
        }
    }
}

public enum HomeLayout {
    /// The mode Home opens in. An approval lives in the chat, so it always opens split; anything else waiting in
    /// the chat (a drop, a reply, a request for the caret: `shouldUnfold`) keeps the chat from opening folded.
    public static func opening(_ start: HomeStart, needsYou: Int, needsAnswer: Bool, chatWaiting: Bool = false) -> HomeMode {
        if needsAnswer { return .split }
        switch start {
        case .writing: return needsYou > 0 ? .split : .writing
        case .split: return .split
        case .now: return chatWaiting ? .split : .reading
        }
    }

    /// ⌘\: from split, fold Now and write; from either fold, back to split.
    public static func toggled(_ mode: HomeMode) -> HomeMode {
        mode == .split ? .writing : .split
    }

    /// Esc mid-draft with Now folded brings Now back first (a peek without losing the text); with an empty field
    /// it closes as before. nil means Esc does what it did before.
    public static func escape(_ mode: HomeMode, hasDraft: Bool) -> HomeMode? {
        mode == .writing && hasDraft ? .split : nil
    }

    /// Typing into the composer folds Now when the setting asks for it.
    public static func afterTyping(_ mode: HomeMode, foldOnType: Bool) -> HomeMode {
        mode == .split && foldOnType ? .writing : mode
    }

    /// The composer grows to 10 lines while Now is folded.
    public static func composerLines(_ mode: HomeMode) -> ClosedRange<Int> {
        mode == .writing ? 1...10 : 1...5
    }

    /// True when the chat has to unfold now.
    public static func shouldUnfold(needsAnswer: Bool, dropPending: Bool, replyNotice: Bool, focusRequested: Bool) -> Bool {
        needsAnswer || dropPending || replyNotice || focusRequested
    }

    /// True when the folded rail shows its amber badge.
    public static func railBadge(needsAnswer: Bool, dropPending: Bool) -> Bool {
        needsAnswer || dropPending
    }
}
