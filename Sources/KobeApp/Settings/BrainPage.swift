import SwiftUI
import KobeKit

/// Settings › Brain: the four doors, a key, and "Use this brain", which hands the key to the engine.
struct BrainPage: View {
    @Bindable var app: AppModel
    @State private var door: Brain?
    @State private var pastedKey = ""
    @State private var checked: Brain?
    @State private var result: (text: String, ok: Bool)?

    private var brain: Brain { door ?? app.settings.selectedBrain }
    private var verdict: KeyVerdict? { checked == brain ? app.brain.verdict : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Brain") { EmptyView() }
            Card(eyebrow: "Model", title: "Pick a brain") {
                if let had = app.brain.hermesAlreadyHas {
                    MutedLine("The engine has: \(had.label)").padding(.bottom, 10)
                }
                LazyVGrid(columns: twoColumns, spacing: 10) {
                    ForEach(Brain.allCases, id: \.self) { b in
                        BrainDoor(brain: b, on: b == brain, note: b == app.settings.selectedBrain ? "In use" : nil) {
                            door = b
                            checked = nil
                            result = nil
                            if b == .ollama { check() }
                        }
                    }
                }
            }
            Card(eyebrow: "Your key", title: brain.label) {
                if brain.needsKey {
                    HStack(spacing: 10) {
                        OnboardingField(placeholder: brain.placeholder, text: $pastedKey, secure: true)
                            .onChange(of: pastedKey) { checked = nil; result = nil }
                        Button("Check") { check() }.buttonStyle(GlassButtonStyle()).disabled(app.brain.busy || pastedKey.isEmpty)
                    }
                } else {
                    HStack(spacing: 10) {
                        Button("Get the recommended model") { app.brain.pullOllamaModel() }.buttonStyle(GlassButtonStyle())
                        Button("Check") { check() }.buttonStyle(GlassButtonStyle())
                        Spacer()
                    }
                }
                if let verdict { BrainVerdictLine(verdict: verdict, brain: brain).padding(.top, 8) }
                Text(brainHelpText(brain)).font(KFont.secondary).foregroundStyle(K.text3).tint(K.lime)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                HStack(spacing: 10) {
                    Button("Use this brain") { use() }.buttonStyle(PrimaryButtonStyle()).disabled(!canUse || app.brain.busy)
                    if app.brain.busy { ProgressView().controlSize(.small) }
                }
                .padding(.top, 12)
                if let result {
                    Text(result.text).font(KFont.secondary).foregroundStyle(result.ok ? K.green : K.red)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
            }
        }
        .onAppear { app.brain.readHermes() }
    }

    private var canUse: Bool {
        if case .works? = verdict { return true }
        return false
    }

    private func check() {
        let picked = brain
        let pasted = pastedKey
        guard !picked.needsKey || !KeyCheck.trimmed(pasted).isEmpty else { return }
        Task {
            await app.brain.check(brain: picked, pasted: pasted)
            if brain == picked { checked = picked }
        }
    }

    private func use() {
        let picked = brain
        Task {
            if picked.needsKey, !app.brain.store(brain: picked, key: KeyCheck.trimmed(pastedKey)) {
                result = ("Kobe couldn't save the key in your Keychain.", false)
                return
            }
            do { try await app.brain.handOver(brain: picked) }
            catch { result = (error.localizedDescription, false); return }
            if let problem = app.brain.problem { result = (problem, false); return }
            app.settings.selectedBrain = picked
            app.brainKeptFromHermes = false
            pastedKey = ""
            checked = nil
            door = nil
            app.brain.readHermes()
            result = ("The engine now uses \(picked.label).", true)
        }
    }
}
