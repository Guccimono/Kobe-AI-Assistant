import SwiftUI
import KobeKit

/// One of the four brain doors; the onboarding step and Settings › Brain both draw it.
struct BrainDoor: View {
    let brain: Brain
    let on: Bool
    var note: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(brain.label).font(KFont.row).foregroundStyle(K.text1)
                    Spacer()
                    if brain.recommended { Text("RECOMMENDED").font(KFont.eyebrow).tracking(0.6).foregroundStyle(K.window)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(K.lime, in: Capsule()) }
                }
                Text(brain.blurb).font(KFont.secondary).foregroundStyle(K.text2).fixedSize(horizontal: false, vertical: true)
                Text(brain.cost).font(KFont.secondary).foregroundStyle(K.text3).padding(.top, 2)
                if let note { Text(note).font(KFont.secondary).foregroundStyle(K.lime) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(on ? K.lime.opacity(0.08) : K.panel, in: RoundedRectangle(cornerRadius: Radius.islandSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.islandSmall, style: .continuous)
                .strokeBorder(on ? K.lime.opacity(0.7) : K.hairline, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The chip and sentence for a key check.
struct BrainVerdictLine: View {
    let verdict: KeyVerdict
    let brain: Brain

    var body: some View {
        let line = KeyCheck.line(verdict, brain: brain)
        HStack(alignment: .top, spacing: 8) {
            StatusChip(text: Self.chipText(line.tone), tone: line.tone.chipTone)
            Text(line.text).font(KFont.secondary).foregroundStyle(line.tone.chipTone.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func chipText(_ tone: KeyTone) -> String {
        switch tone {
        case .ok: "Works"
        case .needsYou: "Check this"
        case .failed: "Refused"
        case .neutral: "Unchecked"
        }
    }
}

/// The door's help line with its one link: the phrase that names where to create the key.
func brainHelpText(_ brain: Brain) -> AttributedString {
    var text = AttributedString(brain.help)
    let phrase = brain == .ollama ? "Install Ollama" : ["Create one at ", "Create a key at "]
        .first { brain.help.contains($0 + brain.maker) }.map { $0 + brain.maker }
    if let phrase, let url = brain.createKeyURL, let range = text.range(of: phrase) {
        text[range].link = url
        text[range].foregroundColor = K.lime
    }
    return text
}
