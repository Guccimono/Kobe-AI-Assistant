import SwiftUI
import KobeKit

/// Settings › Your assistant: name, role, tone and voice. The name is live; role and tone are written to the
/// engine (after a second without typing, or on Return).
struct AssistantPage: View {
    @Bindable var app: AppModel
    @State private var problem: String?
    @State private var pending: Task<Void, Never>?

    private static let fallback = ["af_nova", "am_adam", "af_bella"]

    private var voices: [String] {
        let listed = app.voice.voices
        return listed.isEmpty ? Self.fallback : Array(listed.prefix(3))
    }

    private func label(_ id: String) -> String {
        let tail = id.split(separator: "_").last.map(String.init) ?? id
        return tail.prefix(1).uppercased() + tail.dropFirst()
    }

    var body: some View {
        @Bindable var s = app.settings
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Your assistant") { EmptyView() }
            Card(eyebrow: "Who", title: s.copy.name) {
                SettingRow(title: "Name", detail: "Used everywhere in Kobe, right away.") {
                    OnboardingField(placeholder: Copy.defaultName, text: $s.assistantName).frame(width: 260)
                }
                SettingRow(title: "What it's for", detail: "One line. Kobe writes it into the engine.") {
                    OnboardingField(placeholder: "My ops partner for the café", text: $s.assistantRole)
                        .onSubmit { writeNow() }.frame(width: 320)
                }
                .onChange(of: s.assistantRole) { schedule() }
                SettingRow(title: "Tone") {
                    HStack(spacing: 8) {
                        ForEach(AssistantTone.allCases, id: \.self) { tone in
                            ChoiceChip(title: tone.rawValue.capitalized, on: s.assistantTone == tone) { s.assistantTone = tone }
                        }
                    }
                }
                .onChange(of: s.assistantTone) { schedule() }
                if s.profileSkillOnly {
                    Text("Applies when the Kobe skill is used").font(KFont.secondary).foregroundStyle(K.text3).padding(.top, 6)
                }
                if let problem { Text(problem).font(KFont.secondary).foregroundStyle(K.red).padding(.top, 6) }
            }
            Card(eyebrow: "Voice", title: s.voiceOn ? label(s.voiceName) : "Off") {
                HStack(spacing: 8) {
                    ForEach(voices, id: \.self) { id in
                        ChoiceChip(title: label(id), on: s.voiceOn && s.voiceName == id) { s.voiceName = id; s.voiceOn = true }
                    }
                    ChoiceChip(title: "Off", on: !s.voiceOn) { s.voiceOn = false }
                }
            }
        }
        .onDisappear { if pending != nil { writeNow() } }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await write()
        }
    }

    private func writeNow() {
        pending?.cancel()
        Task { await write() }
    }

    private func write() async {
        pending = nil
        problem = await app.rewriteProfile()
    }
}
