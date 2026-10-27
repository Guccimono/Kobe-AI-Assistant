import SwiftUI
import KobeKit

struct BrainStep: View {
    @Bindable var nav: OnboardingNav
    private var app: AppModel { nav.app }

    var body: some View {
        let name = nav.name
        let selected = app.settings.selectedBrain
        StepHeading(title: "Pick a brain.",
                    lead: "An AI model is what \(name) thinks with. You pay the model's maker directly, with a key they give you. Kobe keeps the key in your Mac's Keychain and hands it to the engine.")
            .onAppear {
                app.brain.readHermes()
                if app.brain.hermesAlreadyHas == nil { app.brainKeptFromHermes = false }
                else if !nav.keepDecided { app.brainKeptFromHermes = true }
            }
        if app.settings.engineSeparateUser {
            StatusRow(color: K.text3, title: "The brain is set where the engine runs",
                      detail: "The engine runs as another user, so its key stays there. Next when you're ready.") { EmptyView() }
                .padding(.bottom, 12)
        }
        if let had = app.brain.hermesAlreadyHas {
            StatusRow(color: K.green, title: "Hermes already has a brain: \(had.label)",
                      detail: "Keep it, or pick another below.") {
                HStack(spacing: 8) {
                    ChoiceChip(title: "Keep it", on: app.brainKeptFromHermes) { nav.keepDecided = true; app.brainKeptFromHermes = true }
                    ChoiceChip(title: "Change", on: !app.brainKeptFromHermes) { nav.keepDecided = true; app.brainKeptFromHermes = false }
                }
            }
            .padding(.bottom, 12)
        }
        if !(app.brainKeptFromHermes && app.brain.hermesAlreadyHas != nil) {
            LazyVGrid(columns: twoColumns, spacing: 10) {
                ForEach(Brain.allCases, id: \.self) { door($0, on: $0 == selected) }
            }
            keyArea(selected)
        }
    }

    private func door(_ brain: Brain, on: Bool) -> some View {
        BrainDoor(brain: brain, on: on) {
            app.settings.selectedBrain = brain
            nav.checkedBrain = nil
            if brain == .ollama { check(brain) }
        }
    }

    @ViewBuilder private func keyArea(_ brain: Brain) -> some View {
        Eyebrow("Your key", color: K.text3).padding(.top, 14).padding(.bottom, 6)
        if brain.needsKey {
            HStack(spacing: 10) {
                OnboardingField(placeholder: brain.placeholder, text: $nav.pastedKey, secure: true)
                    .onChange(of: nav.pastedKey) { nav.checkedBrain = nil }
                Button("Check") { check(brain) }.buttonStyle(GlassButtonStyle()).disabled(app.brain.busy)
            }
        } else {
            HStack(spacing: 10) {
                Button("Get the recommended model") { app.brain.pullOllamaModel() }.buttonStyle(GlassButtonStyle())
                Button("Check") { check(brain) }.buttonStyle(GlassButtonStyle())
                Spacer()
            }
        }
        verdictLine(brain).padding(.top, 8)
        if let problem = nav.saveProblem {
            Text(problem).font(KFont.secondary).foregroundStyle(K.red).padding(.top, 6)
        }
        Text(brainHelpText(brain)).font(KFont.secondary).foregroundStyle(K.text3).tint(K.lime)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
    }

    @ViewBuilder private func verdictLine(_ brain: Brain) -> some View {
        if nav.checkedBrain == brain, let verdict = app.brain.verdict {
            BrainVerdictLine(verdict: verdict, brain: brain)
        }
    }

    private func check(_ brain: Brain) {
        let pasted = nav.pastedKey
        guard !brain.needsKey || !KeyCheck.trimmed(pasted).isEmpty else { return }
        Task {
            await app.brain.check(brain: brain, pasted: pasted)
            if app.settings.selectedBrain == brain { nav.checkedBrain = brain }
        }
    }
}
