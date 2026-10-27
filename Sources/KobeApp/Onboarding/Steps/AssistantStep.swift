import SwiftUI
import KobeKit

struct AssistantStep: View {
    @Bindable var app: AppModel

    /// The mock's three voices, used until Kokoro lists its own.
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
        let settings = app.settings
        @Bindable var s = settings
        StepHeading(title: "Name your assistant.",
                    lead: "This is who you'll be talking to. You can change all of it later in Settings.")
        LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel("Name")
                OnboardingField(placeholder: Copy.defaultName, text: $s.assistantName)
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel("Voice")
                HStack(spacing: 8) {
                    ForEach(voices, id: \.self) { id in
                        ChoiceChip(title: label(id), on: settings.voiceOn && settings.voiceName == id) {
                            settings.voiceName = id
                            settings.voiceOn = true
                        }
                    }
                    ChoiceChip(title: "Off", on: !settings.voiceOn) { settings.voiceOn = false }
                }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel("What it's for (one line)")
            OnboardingField(placeholder: "My ops partner for the café: bookings, suppliers, the website", text: $s.assistantRole)
        }
        .padding(.top, 12)
        Eyebrow("Tone", color: K.text3).padding(.top, 14).padding(.bottom, 6)
        HStack(spacing: 8) {
            ForEach(AssistantTone.allCases, id: \.self) { tone in
                ChoiceChip(title: tone.rawValue.capitalized, on: settings.assistantTone == tone) { settings.assistantTone = tone }
            }
        }
        MutedLine("Kobe writes this as \(settings.copy.name)'s personality in the engine, so it speaks this way from the first message. Your own notes in the engine are never touched.")
            .padding(.top, 14)
    }
}
