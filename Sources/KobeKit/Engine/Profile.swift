import Foundation

/// Who the assistant is, as the person set it up.
public struct Profile: Equatable, Sendable {
    public var name: String
    public var role: String
    public var tone: AssistantTone

    public init(name: String, role: String, tone: AssistantTone) {
        self.name = name
        self.role = role
        self.tone = tone
    }
}

/// The text Kobe writes into the engine for the assistant's profile. No I/O here.
public enum ProfileFiles {
    public static let marker = "<!-- written by Kobe; edit freely, Kobe stops writing it once you do -->"

    /// `~/.hermes/kobe/profile.md`, read by the Kobe skill.
    public static func profileMarkdown(_ p: Profile) -> String {
        let role = oneLine(p.role)
        return "# Profile\n- name: \(Copy(name: p.name).name)\n- role: \(role)\n- tone: \(p.tone.rawValue)\n"
    }

    /// `SOUL.md`: the marker, then the persona. Only written while `mayWriteSoul` allows it.
    public static func soul(_ p: Profile) -> String {
        "\(marker)\n\n# \(Copy(name: p.name).name)\n\n\(persona(p))\n"
    }

    /// True when there is no SOUL.md, or Kobe wrote it and it still starts with the marker. An empty file is
    /// the person's choice and stays theirs.
    public static func mayWriteSoul(existing: String?) -> Bool {
        guard let existing else { return true }
        let first = existing.prefix(while: { !$0.isNewline })
        return first.trimmingCharacters(in: .whitespacesAndNewlines) == marker
    }

    public static func systemPrompt(_ p: Profile) -> String { persona(p) }

    public static func hello(_ p: Profile) -> String {
        Copy(name: p.name).hello(role: p.role)
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func persona(_ p: Profile) -> String {
        let name = Copy(name: p.name).name
        let role = oneLine(p.role)
        let who = role.isEmpty ? "a personal assistant living in the notch of this Mac" : role
        let tone: String
        switch p.tone {
        case .direct: tone = "Be direct: answer first, reasons after, no padding."
        case .warm: tone = "Be warm: friendly and encouraging, still concise."
        case .brief: tone = "Be brief: one or two sentences unless asked for more."
        }
        return "You are \(name), \(who). \(tone)"
    }
}
