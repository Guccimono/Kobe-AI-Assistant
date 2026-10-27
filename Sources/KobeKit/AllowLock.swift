import Foundation

/// Whether ⌥⌘Y may allow a request: only while a card shows it on screen and every card showing it has had its
/// whole text in view. Fail safe: no card on screen (a folded chat, another page, the notch closed) is locked, and a
/// card that goes takes its "seen" with it. The Allow button itself always works.
public struct AllowLock: Equatable, Sendable {
    /// The cards on screen right now (one view instance each), and whether each is still locked.
    private var cards: [UUID: Bool] = [:]

    public init() {}

    public var locked: Bool { cards.isEmpty || cards.values.contains(true) }

    /// A card's state: `locked` while its end hasn't been seen, nil once it is off screen.
    public mutating func report(_ card: UUID, locked: Bool?) { cards[card] = locked }
}
