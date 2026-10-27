import AppKit
import SwiftUI
import KobeKit

/// Settings › Engine: everything the first run's engine step did, changeable later.
struct EnginePage: View {
    @Bindable var app: AppModel
    @State private var pasted = ""
    @State private var note: String?
    @State private var rotating = false
    private static let guide = URL(string: "https://hermes-agent.nousresearch.com/docs/getting-started/installation/")!

    private var engine: EngineService { app.engine }

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Engine") {
                HStack(spacing: 8) {
                    if engine.busy { ProgressView().controlSize(.small) }
                    Button("Check") { check() }.buttonStyle(PrimaryButtonStyle()).disabled(engine.busy)
                }
            }
            Card(eyebrow: "Hermes", title: stateTitle) {
                statusRow
                if let problem = engine.problem {
                    Text(problem).font(KFont.secondary).foregroundStyle(K.amber).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                if engine.state == .notInstalled { guideLine.padding(.top, 10) }
            }
            Card(eyebrow: "Connection", title: connectionTitle) {
                SettingRow(title: "Engine address", detail: "host:port where Hermes answers. A change applies to the next request.") {
                    OnboardingField(placeholder: AppSettings.defaultServerURL, text: $settings.serverURL).frame(width: 260)
                }
                SettingRow(title: "Private key",
                           detail: keyDetail) {
                    HStack(spacing: 8) {
                        if rotating { ProgressView().controlSize(.small) }
                        Button("Rotate the private key") { rotate() }.buttonStyle(GlassButtonStyle())
                            .disabled(rotating || engine.busy || settings.engineSeparateUser)
                    }
                }
                if settings.engineSeparateUser {
                    Text(EngineService.elsewhereMessage).font(KFont.secondary).foregroundStyle(K.text3).padding(.top, 6)
                }
                if let note { Text(note).font(KFont.secondary).foregroundStyle(K.text2).padding(.top, 6) }
            }
            Card(eyebrow: "Advanced", title: "Other setups") {
                SettingRow(title: "Hermes runs as another user", detail: "Kobe and the engine share a folder instead.") {
                    Toggle("", isOn: $settings.engineSeparateUser).labelsHidden().toggleStyle(.switch).tint(K.lime)
                }
                .onChange(of: settings.engineSeparateUser) { app.applyExchangeSettings() }
                SettingRow(title: "Exchange folder", detail: "Where Kobe and the engine trade files. Return applies it.") {
                    HStack(spacing: 8) {
                        OnboardingField(placeholder: ExchangeSettings.defaultFolder, text: $settings.exchangeFolder)
                            .onSubmit { app.applyExchangeSettings() }.frame(width: 260)
                        Button("Show") { NSWorkspace.shared.open(SnapshotFolder.root) }.buttonStyle(GlassButtonStyle())
                    }
                }
                SettingRow(title: "Paste the engine key", detail: "Use this when the engine already has a key Kobe doesn't.") {
                    HStack(spacing: 8) {
                        OnboardingField(placeholder: "Paste the engine key", text: $pasted, secure: true).frame(width: 220)
                        Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(pasted.isEmpty)
                    }
                }
            }
        }
        .task { await check() }
    }

    private var connected: Bool { if case .connected = app.connection.state { true } else { false } }
    private var connectionTitle: String { connected ? "Connected" : app.key.isSet ? "Key set, engine not answering" : "No key yet" }
    private var keyDetail: String {
        connected ? "Connected · rotate to make a new one. Other apps using the old key will need it."
            : app.key.isSet ? "Kobe has a key, but the engine isn't answering with it." : "Kobe has no key for the engine yet."
    }

    private var stateTitle: String {
        engine.state.map(EngineDetection.title) ?? "Looking for Hermes Agent…"
    }

    @ViewBuilder private var statusRow: some View {
        let base = engine.baseURL
        switch engine.state {
        case nil:
            StatusRow(color: K.text3, title: "Looking…", detail: "Asking \(base.host() ?? "127.0.0.1")") { EmptyView() }
        case .running(let version)?:
            StatusRow(color: K.green, title: "Hermes is running",
                      detail: EngineDetection.line(.running(version: version), base: base)) { EmptyView() }
        case .installedApiOff?:
            StatusRow(color: K.amber, title: "Hermes is installed, but not answering",
                      detail: EngineDetection.line(.installedApiOff, base: base)) {
                Button("Turn it on") { Task { await turnOn() } }.buttonStyle(PrimaryButtonStyle())
                    .disabled(engine.busy || app.settings.engineSeparateUser)
            }
        case .notInstalled?:
            StatusRow(color: K.red, title: "Hermes isn't installed yet",
                      detail: EngineDetection.line(.notInstalled, base: base)) {
                Button("Install Hermes") { engine.install() }.buttonStyle(PrimaryButtonStyle()).disabled(engine.busy)
            }
        }
    }

    private var guideLine: some View {
        var text = AttributedString("Prefer to do it yourself? Hermes install guide, then press Check again.")
        if let range = text.range(of: "Hermes install guide") {
            text[range].link = Self.guide
            text[range].foregroundColor = K.lime
        }
        return Text(text).font(KFont.secondary).foregroundStyle(K.text3).tint(K.lime)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A successful check with a key set means the engine is connected from here.
    private func check() {
        Task { await check() }
    }

    private func check() async {
        await engine.check()
        if case .running? = engine.state, app.key.isSet { app.finishOnboardingFromSettings() }
    }

    private func turnOn() async {
        await engine.turnOn()
        if case .running? = engine.state, app.key.isSet { app.finishOnboardingFromSettings() }
        app.reconnect()
    }

    private func rotate() {
        rotating = true
        note = nil
        Task {
            note = await app.rotateEngineKey() ?? "New key in place."
            rotating = false
        }
    }

    private func save() {
        guard app.key.save(pasted) else { note = "That key is empty."; return }
        pasted = ""
        app.finishOnboardingFromSettings()
        note = "Saved."
        app.reconnect()
        check()
    }
}
