import AppKit
import SwiftUI
import KobeKit

struct EngineStep: View {
    @Bindable var app: AppModel
    @State private var advanced = false
    @State private var pastedKey = ""
    private static let guide = URL(string: "https://hermes-agent.nousresearch.com/docs/getting-started/installation/")!

    private var engine: EngineService { app.engine }

    var body: some View {
        let name = app.settings.copy.name
        StepHeading(title: engine.state.map(EngineDetection.title) ?? "Looking for Hermes Agent…",
                    lead: "Hermes is the engine behind \(name). It runs on this Mac, under your account. Kobe checks for it, and installs it only when you click.")
            .task { await engine.check() }
        statusRow
        if let problem = engine.problem {
            Text(problem).font(KFont.secondary).foregroundStyle(K.amber).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        if engine.state == .notInstalled {
            guideLine.padding(.top, 10)
        }
        if engine.needsKeyChoice { keyPaste.padding(.top, 10) }
        advancedSection.padding(.top, 16)
    }

    @ViewBuilder private var statusRow: some View {
        let base = engine.baseURL
        switch engine.state {
        case nil:
            StatusRow(color: K.text3, title: "Looking…", detail: "Asking \(base.host() ?? "127.0.0.1")") { checkButton }
        case .running(let version)?:
            StatusRow(color: K.green, title: "Hermes is running",
                      detail: EngineDetection.line(.running(version: version), base: base)) { checkButton }
        case .installedApiOff?:
            StatusRow(color: K.amber, title: "Hermes is installed, but not answering",
                      detail: EngineDetection.line(.installedApiOff, base: base)) {
                checkButton
                Button("Turn it on") { Task { await engine.turnOn() } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(engine.busy || app.settings.engineSeparateUser)
            }
            if app.settings.engineSeparateUser {
                Text(EngineService.elsewhereMessage).font(KFont.secondary).foregroundStyle(K.text3).padding(.top, 6)
            }
        case .notInstalled?:
            StatusRow(color: K.red, title: "Hermes isn't installed yet",
                      detail: EngineDetection.line(.notInstalled, base: base)) {
                checkButton
                Button("Install Hermes") { engine.install() }.buttonStyle(PrimaryButtonStyle()).disabled(engine.busy)
            }
        }
    }

    private var guideLine: some View {
        var text = AttributedString("Prefer to do it yourself? Hermes install guide, then come back and press Check again.")
        if let range = text.range(of: "Hermes install guide") {
            text[range].link = Self.guide
            text[range].foregroundColor = K.lime
        }
        return Text(text).font(KFont.secondary).foregroundStyle(K.text3).tint(K.lime)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var checkButton: some View {
        HStack(spacing: 8) {
            if engine.busy { ProgressView().controlSize(.small) }
            Button("Check") { Task { await engine.check() } }.buttonStyle(GlassButtonStyle()).disabled(engine.busy)
        }
    }

    private var keyPaste: some View {
        HStack(spacing: 10) {
            OnboardingField(placeholder: "Paste the engine key", text: $pastedKey, secure: true).frame(maxWidth: 360)
            Button("Save") { saveKey() }.buttonStyle(PrimaryButtonStyle()).disabled(pastedKey.isEmpty)
        }
    }

    private func saveKey() {
        guard app.key.save(pastedKey) else { return }
        pastedKey = ""
        Task { await engine.check() }
    }

    @ViewBuilder private var advancedSection: some View {
        @Bindable var s = app.settings
        Button { advanced.toggle() } label: {
            HStack(spacing: 6) {
                Icon(icon: advanced ? .caretDown : .caretRight, size: 12)
                Text("Advanced").font(KFont.row)
            }
            .foregroundStyle(K.text2).contentShape(.rect)
        }
        .buttonStyle(.plain)
        if advanced {
            VStack(alignment: .leading, spacing: 4) {
                SettingRow(title: "Engine address", detail: "host:port where Hermes answers") {
                    OnboardingField(placeholder: AppSettings.defaultServerURL, text: $s.serverURL).frame(width: 260)
                }
                SettingRow(title: "Hermes runs as another user", detail: "Kobe and the engine share a folder instead.") {
                    Toggle("", isOn: $s.engineSeparateUser).labelsHidden().toggleStyle(.switch)
                }
                .onChange(of: s.engineSeparateUser) { app.applyExchangeSettings() }
                if app.settings.engineSeparateUser {
                    SettingRow(title: "Exchange folder", detail: "A folder both users can reach. Return applies it.") {
                        OnboardingField(placeholder: ExchangeSettings.sharedFolder, text: $s.exchangeFolder)
                            .onSubmit { app.applyExchangeSettings() }.frame(width: 260)
                    }
                    keyPaste
                }
            }
            .padding(.top, 6)
        }
    }
}
