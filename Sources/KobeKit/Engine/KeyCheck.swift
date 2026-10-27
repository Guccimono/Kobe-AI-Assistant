import Foundation

public enum KeyVerdict: Equatable, Sendable {
    case works(models: Int)
    case wrongProvider(looksLike: Brain)
    case refused(by: Brain)
    case unreachable
}

/// Mirrors the app's `ChipTone` (which lives in the app target) so the sentence and its tone travel together.
public enum KeyTone: Equatable, Sendable { case ok, needsYou, failed, neutral }

public enum KeyCheck {
    public static func trimmed(_ pasted: String) -> String {
        pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Longer prefixes first: `sk-ant-` and `sk-or-` before the bare `sk-`.
    public static func sniff(_ key: String) -> Brain? {
        if key.hasPrefix("sk-ant-") { return .claude }
        if key.hasPrefix("sk-or-") { return .openrouter }
        if key.hasPrefix("sk-") { return .openai }
        return nil
    }

    /// A 200 works. Otherwise a prefix that belongs to another door beats a refusal; no answer is unreachable.
    public static func verdict(brain: Brain, key: String, status: Int?, modelCount: Int?) -> KeyVerdict {
        guard let status else { return .unreachable }
        if status == 200 { return .works(models: modelCount ?? 0) }
        // Only 401 and 403 mean the key was refused; 429, 5xx and the rest mean we could not get an answer.
        guard status == 401 || status == 403 else { return .unreachable }
        if brain.needsKey, let other = sniff(trimmed(key)), other != brain { return .wrongProvider(looksLike: other) }
        return .refused(by: brain)
    }

    public static func line(_ v: KeyVerdict, brain: Brain) -> (text: String, tone: KeyTone) {
        switch v {
        case .works(let n):
            ("Key works. \(n) models available.", .ok)
        case .wrongProvider(let other):
            ("This looks like \(other.article) \(other.label) key, not \(brain.article) \(brain.label) one. Pick \(other.label) above, or create \(brain.article) \(brain.label) key.", .needsYou)
        case .refused(let by):
            ("\(by.maker) doesn't recognise this key. Check you copied the whole thing.", .failed)
        case .unreachable:
            ("Can't reach \(brain.maker) right now. You can continue and check later.", .neutral)
        }
    }
}
