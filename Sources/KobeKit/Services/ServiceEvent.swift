import Foundation

/// Something a connection noticed in the background: a badge on its pill and a sound, and in Kobe
/// also the notification band. A WhatsApp event never carries the message text, only the chat's name.
public struct ServiceEvent: Equatable, Sendable {
    /// Badges: finished (green check), error (red cross), attention (amber, needs you).
    public enum Kind: Equatable, Sendable { case finished, error, attention }
    /// Sound names; Kobe plays its own quiet system sounds for them.
    public enum Sound: Equatable, Sendable { case finish, error, question, pop, silent }

    /// The pill: "stripe", "github", "vercel" or "whatsapp".
    public let pill: String
    public let kind: Kind
    /// The band's right-hand text, e.g. "+12.00 · Jane Doe", "my-site · Ready", "CI failing on repo".
    public let detail: String
    public let sound: Sound

    public init(pill: String, kind: Kind, detail: String, sound: Sound) {
        self.pill = pill
        self.kind = kind
        self.detail = detail
        self.sound = sound
    }
}
