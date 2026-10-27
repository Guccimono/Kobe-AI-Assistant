import Foundation

/// The assistant's name in the app's own words. "Kobe" is the app; the assistant answering in it has a name the
/// user picks (`AppSettings.assistantName`), and every line that speaks of it is built here. A blank name reads
/// as "Kobe".
public struct Copy: Sendable, Equatable {
    public static let defaultName = "Kobe"

    public let name: String

    public init(name: String) {
        let trimmed = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        self.name = trimmed.isEmpty ? Self.defaultName : trimmed
    }

    public var ask: String { "Ask \(name)…" }
    public var askOrDrop: String { "Ask \(name)… or drop a file here" }
    public var thinking: String { "\(name) is thinking…" }
    public var needsYou: String { "\(name) needs you" }
    public var replied: String { "\(name) replied" }
    public var newChat: String { "New chat with \(name)" }
    public var memory: String { "Open \(name)'s memory" }
    public var work: String { "\(name)'s work" }
    /// The first line when the assistant meets the user. The role is not used yet.
    public func hello(role: String?) -> String {
        "Hi. I'm here in your notch now. Want to start with your calendar or your inbox?"
    }
}
