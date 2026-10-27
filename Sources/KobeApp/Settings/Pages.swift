import AppKit
import SwiftUI
import KobeKit

// MARK: - Home

struct HomePage: View {
    let app: AppModel
    let selection: SettingsSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Home") {
                Button { newChat() } label: { HStack(spacing: 6) { Icon(icon: .plus, size: 12); Text("New chat") } }
                    .buttonStyle(PrimaryButtonStyle())
            }
            HStack(alignment: .top, spacing: 16) {
                Card(eyebrow: "Your assistant", title: app.settings.copy.name) {
                    Button("Set up again") { setUpAgain() }.buttonStyle(GlassButtonStyle()).padding(.bottom, 14)
                    HStack(spacing: 40) {
                        BigNumber(value: "\(chatsThisWeek)", label: "chats this week")
                        BigNumber(value: "\(app.approvalsToday)", label: "approvals today",
                                  chip: app.needsAnswer ? StatusChip(text: "1 waiting", tone: .amber) : nil)
                    }
                }
                .frame(maxWidth: .infinity)
                KeepAwakeCard(app: app).frame(maxWidth: .infinity)
            }
            HStack(alignment: .top, spacing: 16) {
                Card(eyebrow: "Recent", title: "Chats") {
                    ForEach(app.chats.sessions.prefix(4)) { session in
                        ListRow(icon: session.source == "whatsapp" ? .whatsappLogoFill : .chatCircle, title: session.displayTitle,
                                subtitle: session.sourceLabel(copy: app.settings.copy)) { EmptyView() }
                    }
                    if app.chats.sessions.isEmpty {
                        Text("No chats yet.").font(KFont.body).foregroundStyle(K.text3)
                    }
                    CardActionButton(title: "All chats") { selection.page = .chats }
                }
                .frame(maxWidth: .infinity)
                ConnectionsCard(app: app) { selection.page = .connections }.frame(maxWidth: .infinity)
            }
        }
    }

    private var chatsThisWeek: Int {
        let weekAgo = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        return app.chats.sessions.filter { ($0.lastActive ?? 0) >= weekAgo }.count
    }

    private func newChat() { app.newChat() }

    private func setUpAgain() {
        app.resetOnboarding()
        OnboardingWindow.show(app, at: .welcome)
    }
}

struct KeepAwakeCard: View {
    let app: AppModel

    var body: some View {
        Card(eyebrow: "Keep awake", title: app.keepAwake.isActive ? app.keepAwake.statusText : "Off",
             trailing: AnyView(Toggle("", isOn: Binding(get: { app.keepAwake.isActive }, set: { app.setKeepAwake(minutes: $0 ? 60 : nil) }))
                .toggleStyle(.switch).labelsHidden().tint(K.lime))) {
            Segmented(options: KeepAwake.choices.map { $0 == 0 ? "Until off" : KeepAwake.label(minutes: $0) }, selected: selectedIndex) {
                app.setKeepAwake(minutes: KeepAwake.choices[$0])
            }
            .padding(4)
            .overlay(Capsule().strokeBorder(K.hairline, lineWidth: 1))
        }
    }

    private var selectedIndex: Int {
        guard app.keepAwake.isActive else { return -1 }
        guard let ends = app.keepAwake.endsAt else { return 3 }
        let minutes = ends.timeIntervalSinceNow / 60
        return minutes > 60 ? 2 : minutes > 30 ? 1 : 0
    }
}

/// Home's connections card: the same status list as the Connections page; `more` opens that page (nil there).
struct ConnectionsCard: View {
    let app: AppModel
    var more: (() -> Void)?

    var body: some View {
        Card(eyebrow: "From the snapshots", title: "Connections") {
            ConnectionStatusList(app: app)
            if let more { CardActionButton(title: "All connections", action: more) }
        }
    }
}

/// One row per strip connection, read from its snapshot: name, the snapshot's status chip and "updated 4 min
/// ago · via Kobe Agent", "· via the app" (who runs it now, `Handover`) or "· on this Mac" for the Mac apps;
/// "never updated" before the first file.
/// The ages redraw every 30 s, only while it is on screen.
struct ConnectionStatusList: View {
    let app: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 0) {
                ForEach(StripLayout.order.filter { $0 != .now }, id: \.self) { id in
                    let status = app.snapshots.envelopes[id]?.status
                    let runner = MacConnectionCopy.runner(id, owner: app.owner(id))
                    ListRow(icon: StripLayout.icon(id), title: StripLayout.name(id),
                            subtitle: SnapshotRules.metaText(app.snapshots.freshness(id), source: runner)) {
                        StatusChip(text: StripLayout.statusText(status ?? .notSetUp), tone: ChipTone(status))
                    }
                }
            }
        }
    }
}

// MARK: - Chats

struct ChatsPage: View {
    let app: AppModel
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Chats") {
                HStack(spacing: 8) {
                    Icon(icon: .magnifyingGlass, size: 15).foregroundStyle(K.text3)
                    TextField("Search chats…", text: $search).textFieldStyle(.plain).frame(width: 200)
                }
                .padding(.horizontal, 16).padding(.vertical, 10).background(K.panel, in: Capsule())
                Button { app.newChat() } label: {
                    HStack(spacing: 6) { Icon(icon: .plus, size: 14); Text("New chat") }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            Card {
                ForEach(filtered) { session in
                    Button { app.openChat(session) } label: {
                        ListRow(icon: session.source == "whatsapp" ? .whatsappLogoFill : .chatCircle, title: session.displayTitle,
                                subtitle: session.preview) {
                            StatusChip(text: session.sourceLabel(copy: app.settings.copy), tone: .green)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete chat…", role: .destructive) { ChatDeletion.confirm(session, app: app) }
                    }
                }
                if filtered.isEmpty { Text("Nothing here yet.").font(KFont.body).foregroundStyle(K.text3) }
            }
        }
        .task { await app.chats.refreshSessions() }
    }

    private var filtered: [HermesSession] {
        guard !search.isEmpty else { return app.chats.sessions }
        return app.chats.sessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(search) || ($0.preview ?? "").localizedCaseInsensitiveContains(search) }
    }
}

// MARK: - Connections

struct ConnectionsPage: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Connections") {
                Button("Refresh") { app.connectionServices.values.forEach { $0.refresh() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
            ConnectionsCard(app: app)
            // The app's own keys, for the connectors its shim still runs. Once Kobe Agent runs one (its file is fresh
            // and says so), that row asks to remove the app's copy.
            StripeSettingsSection(app: app)
            GitHubSettingsSection(app: app)
            VercelSettingsSection(app: app)
            WhatsAppSettingsSection(app: app)
            MacSettingsSection(app: app)
            Text("Keys stay in your Keychain on this Mac. Kobe checks these services in the background to tell you about payments, deploys, CI and messages.")
                .font(KFont.secondary).foregroundStyle(K.text3)
        }
    }
}

/// One service key: write-only field, Save, Remove, and a link to create the key. After a change the service
/// fetches at once and the row shows the result.
struct KeyRow: View {
    let app: AppModel
    let service: Service
    let title: String
    let hint: String
    let create: URL?
    @State private var pasted = ""
    @State private var note: String?
    @State private var version = 0

    var body: some View {
        let isSet = { _ = version; return app.keys.isSet(service) }()
        let byAgent = WidgetID(rawValue: service.rawValue).map { app.owner($0) == .agent } ?? false
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(KFont.row).foregroundStyle(K.text1)
                if byAgent {
                    StatusChip(text: "Via Kobe Agent", tone: .green)
                } else {
                    StatusChip(text: isSet ? "Key stored" : "No key", tone: isSet ? .green : .amber)
                }
                Spacer()
            }
            if byAgent {
                agentRow(isSet: isSet)
            } else {
                keyFields(isSet: isSet)
            }
        }
        .padding(.vertical, 8)
    }

    /// Kobe Agent runs this connector with its own key: the app's copy is only a leftover, so the row offers to
    /// remove it (only the app's Keychain item; Kobe Agent's key is untouched).
    @ViewBuilder private func agentRow(isSet: Bool) -> some View {
        Text(note ?? (isSet ? "Kobe Agent has its own key. Remove this one: the app doesn't need it any more."
                            : "Kobe Agent has its own key. Nothing is stored on this Mac's app."))
            .font(KFont.secondary).foregroundStyle(K.text3).fixedSize(horizontal: false, vertical: true)
        if isSet {
            Button("Remove") { remove() }.buttonStyle(DangerButtonStyle()).fixedSize()
        }
    }

    @ViewBuilder private func keyFields(isSet: Bool) -> some View {
        Text(note ?? hint).font(KFont.secondary).foregroundStyle(K.text3).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            SecureField(isSet ? "Replace key" : "Paste key", text: $pasted).textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: 360)
                .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(pasted.isEmpty).fixedSize()
            if isSet {
                Button("Remove") { remove() }.buttonStyle(DangerButtonStyle()).fixedSize()
            } else if let create {
                Button("Create") { NSWorkspace.shared.open(create) }.buttonStyle(GlassButtonStyle()).fixedSize()
            }
            Spacer()
        }
    }

    private var owner: (any ConnectionService)? { app.connectionServices[service.rawValue] }

    private func save() {
        let typed = pasted
        pasted = ""
        Task {
            if await app.saveServiceKey(typed, for: service) {
                version += 1
                note = "Saved. Checking…"
                note = await owner?.keyChanged() ?? "Connected."
            } else {
                note = service == .stripe && typed.hasPrefix("sk_") ? "Use a restricted read-only key (rk_…), not a full secret key." : "That key is empty."
            }
        }
    }

    private func remove() {
        Task {
            await app.removeServiceKey(service)
            version += 1
            note = "Removed."
            _ = await owner?.keyChanged()
        }
    }
}

// MARK: - Claude Code

struct ClaudePage: View {
    let app: AppModel
    @State private var plan: ClaudeSettingsPlan?
    @State private var message: String?
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Claude Code") {
                if app.claudeHooksInstalled {
                    if app.claudeHooksOutOfDate {
                        Button("Install again") { prepare(remove: false) }.buttonStyle(PrimaryButtonStyle())
                    }
                    Button("Remove hooks") { prepare(remove: true) }.buttonStyle(DangerButtonStyle())
                } else {
                    Button("Install hooks") { prepare(remove: false) }.buttonStyle(PrimaryButtonStyle())
                }
            }
            Card(eyebrow: "In the notch", title: "Claude Code sessions") {
                ListRow(icon: .terminalWindowFill, title: "Hooks in ~/.claude/settings.json",
                        subtitle: app.claudeHooksOutOfDate ? "Written for another wait time: install again to update." : nil) {
                    StatusChip(text: app.claudeHooksOutOfDate ? "Out of date" : app.claudeHooksInstalled ? "Installed" : "Not installed",
                               tone: app.claudeHooksOutOfDate ? .amber : app.claudeHooksInstalled ? .green : .amber)
                }
                ListRow(icon: .plug, title: "Listening for Claude Code") {
                    StatusChip(text: app.claudeListening ? "On" : "Off", tone: app.claudeListening ? .green : .red)
                }
                Text("Installing replaces the old Kobe hook in one step. A dated backup of settings.json is made first, and you see every change before anything is written.")
                    .font(KFont.secondary).foregroundStyle(K.text3).padding(.top, 12)
                if let message { Text(message).font(KFont.secondary).foregroundStyle(K.text2).padding(.top, 8).textSelection(.enabled) }
            }
        }
        .sheet(item: Binding(get: { plan.map(IdentifiedPlan.init) }, set: { plan = $0?.plan })) { wrapped in
            ConfirmSheet(plan: wrapped.plan, removing: removing) { confirmed in
                if confirmed { apply(wrapped.plan) }
                plan = nil
            }
        }
    }

    private func prepare(remove: Bool) {
        removing = remove
        let text = try? String(contentsOf: AppModel.claudeSettingsURL, encoding: .utf8)
        do {
            plan = remove ? try ClaudeSettingsInstaller.uninstallPlan(settings: text ?? "", hookPath: app.hookPath)
                : try ClaudeSettingsInstaller.plan(settings: text, hookPath: app.hookPath, wait: app.settings.claudeWait)
        } catch {
            message = "~/.claude/settings.json isn't valid JSON, so nothing was changed. Fix it, then try again."
        }
    }

    private func apply(_ plan: ClaudeSettingsPlan) {
        do {
            let backup = try ClaudeSettingsInstaller.apply(plan, to: AppModel.claudeSettingsURL, now: Date())
            message = (removing ? "Removed. " : "Installed. ") + (backup.map { "Backup: \($0.path)" } ?? "")
        } catch ClaudeSettingsInstaller.InstallerError.changedSinceShown {
            message = "settings.json changed while you were reading. Nothing was written; try again."
        } catch {
            message = "Couldn't write settings.json: \(error.localizedDescription)"
        }
        app.refreshClaudeHookState()
    }
}

struct IdentifiedPlan: Identifiable {
    let plan: ClaudeSettingsPlan
    var id: String { plan.updated }
}

/// Shows exactly what will change in settings.json; nothing is written until the primary (or, removing, red) button.
struct ConfirmSheet: View {
    let plan: ClaudeSettingsPlan
    let removing: Bool
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Review")
            Text(removing ? "Remove Kobe's hooks" : "Install Kobe's hooks").font(.system(size: 22, weight: .bold)).foregroundStyle(K.text1)
            if !plan.removedCommands.isEmpty {
                Text("Removes \(plan.removedCommands.count) hook entries.")
                    .font(KFont.secondary).foregroundStyle(K.text2)
            }
            ScrollView {
                Text(diffText).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.buttonStyle(GlassButtonStyle())
                if removing {
                    Button("Remove hooks") { done(true) }.buttonStyle(DangerButtonStyle())
                } else {
                    Button("Install the hook") { done(true) }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(26)
        .frame(width: 760, height: 620)
        .background(K.panel)
    }

    private var diffText: AttributedString {
        var out = AttributedString()
        for line in ClaudeSettingsInstaller.diff(plan).split(separator: "\n", omittingEmptySubsequences: false) {
            var part = AttributedString(line + "\n")
            part.foregroundColor = line.hasPrefix("+ ") ? K.green : line.hasPrefix("- ") ? K.red : K.text3
            out += part
        }
        return out
    }
}

// MARK: - Notch

struct GeneralPage: View {
    let app: AppModel

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "General") { EmptyView() }
            Card(eyebrow: "Where Kobe shows", title: "Notch and menu bar") {
                SettingRow(title: "Show in the notch", detail: "Off: the notch only appears when something needs you or when you open a chat.") {
                    Toggle("", isOn: $settings.showNotch).toggleStyle(.switch).labelsHidden().tint(K.lime)
                }
                SettingRow(title: "Show in the menu bar", detail: "The Kobe icon; a click opens these settings. One of the two always stays on.") {
                    Toggle("", isOn: $settings.showMenuBar).toggleStyle(.switch).labelsHidden().tint(K.lime)
                }
            }
            Card(eyebrow: "Notch", title: "Behaviour") {
                SettingRow(title: "Wings on hover", detail: "Resting the pointer on the notch spreads it into the wings; a click opens it. Off: nothing on hover.") {
                    Toggle("", isOn: $settings.openOnHover).toggleStyle(.switch).labelsHidden().tint(K.lime)
                }
                SettingRow(title: "Close when the pointer leaves", detail: "On: the open notch folds half a second after you leave it. Off: it stays until you click outside, press Esc or ✕.") {
                    Toggle("", isOn: $settings.closeOnLeave).toggleStyle(.switch).labelsHidden().tint(K.lime)
                }
                SettingRow(title: "Home opens on",
                           detail: "Writing first: the chat with Now folded to a rail, split when something needs you. Now first: Now with the chat folded.") {
                    Segmented(options: HomeStart.allCases.map(\.label),
                              selected: HomeStart.allCases.firstIndex(of: settings.homeStart) ?? 0) {
                        settings.homeStart = HomeStart.allCases[$0]
                    }
                }
                SettingRow(title: "Fold Now when I start typing", detail: "The field grows to ten lines; ⌘\\, Esc or a click on the rail brings Now back.") {
                    Toggle("", isOn: $settings.foldNowOnType).toggleStyle(.switch).labelsHidden().tint(K.lime)
                }
                SettingRow(title: "Reopen where I left off",
                           detail: "For this long after the notch folds, it opens on the page you were on (a note you're working on). Then Home.") {
                    Segmented(options: ResumePage.choices.map { $0 == 0 ? "Off" : "\($0) min" },
                              selected: ResumePage.choices.firstIndex(of: settings.resumeMinutes) ?? 2) {
                        settings.resumeMinutes = ResumePage.choices[$0]
                    }
                }
                SettingRow(title: "Open after", detail: "How long the pointer rests on the notch first. Shorter feels snappier.") {
                    Segmented(options: ["Instant", "0.1 s", "0.25 s", "0.5 s"],
                              selected: [0, 0.1, 0.25, 0.5].firstIndex(of: settings.hoverDelay) ?? 1) {
                        settings.hoverDelay = [0, 0.1, 0.25, 0.5][$0]
                    }
                }
                SettingRow(title: "Open Kobe at login") {
                    Toggle("", isOn: Binding(get: { settings.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden().tint(K.lime)
                }
                SettingRow(title: "Auto-close", detail: "How long a finished card stays before the notch folds.") {
                    Segmented(options: ["10s", "15s", "30s"], selected: AppSettings.autoCloseChoices.firstIndex(of: settings.autoCloseSeconds) ?? 1) {
                        settings.autoCloseSeconds = AppSettings.autoCloseChoices[$0]
                    }
                }
                SettingRow(title: "Size", detail: "Drag the bar under the open notch; double-click it to reset.") {
                    Button("Reset size") { settings.notchHeight = 0; settings.notchWidth = 0 }.buttonStyle(GlassButtonStyle())
                }
                SettingRow(title: "Claude Code waits", detail: "Seconds a permission or question waits for you. After a change, install the hooks again (Claude Code page).") {
                    Stepper("\(settings.claudeWait) s", value: $settings.claudeWait, in: 30...300, step: 15).foregroundStyle(K.text1)
                        .onChange(of: settings.claudeWait) { app.refreshClaudeHookState() }
                }
            }
            // Sounds sit with the notch's behaviour now that the gear opens this window instead of a quick panel.
            Card(eyebrow: "Sound", title: settings.soundOn ? "On" : "Off") {
                SettingRow(title: "Play sounds", detail: "Done, needs you, error. Quiet system sounds.") {
                    Toggle("", isOn: $settings.soundOn).toggleStyle(.switch).labelsHidden().tint(K.lime)
                }
                SettingRow(title: "Volume") {
                    Slider(value: $settings.soundVolume, in: 0...1).frame(width: 220).disabled(!settings.soundOn)
                }
            }
        }
    }
}

struct KeepAwakePage: View {
    let app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Keep awake") { EmptyView() }
            KeepAwakeCard(app: app)
        }
    }
}

struct ShortcutsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Shortcuts") { EmptyView() }
            Card(eyebrow: "From any app", title: "Shortcuts") {
                row("Quick ask", "⌃⌥Space")
                row("Allow what waits", "⌥⌘Y")
                row("Deny what waits", "⌥⌘N")
                row("Close the notch", "esc")
                row("Send", "Return")
            }
        }
    }

    private func row(_ title: String, _ keys: String) -> some View {
        SettingRow(title: title) {
            Text(keys).font(KFont.row).foregroundStyle(K.text1)
                .padding(.horizontal, 10).padding(.vertical, 5).background(K.glass, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        }
    }
}

/// "Delete chat…": asks first, then deletes it in Hermes (messages included).
@MainActor
enum ChatDeletion {
    static func confirm(_ session: HermesSession, app: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(session.displayTitle)\u{201D}?"
        alert.informativeText = "The chat and its messages are deleted from \(app.settings.copy.name). This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await app.chats.delete(session) }
    }
}

struct VoicePage: View {
    let app: AppModel

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Voice") {
                Button("Test voice") { app.voice.speak("Hi, this is \(settings.copy.name). At 3:30 pm I'll remind you about the quote.", settings: settings) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!settings.voiceOn)
            }
            Card(eyebrow: "Spoken replies", title: settings.voiceOn ? "On" : "Off") {
                SettingRow(title: "Read \(settings.copy.name)'s replies aloud", detail: "Kokoro on this Mac for English, Spanish and French; the macOS voice otherwise. Nothing leaves your Mac.") {
                    Toggle("", isOn: $settings.voiceOn).toggleStyle(.switch).labelsHidden().tint(K.lime)
                }
                ListRow(icon: .speakerHigh, title: "Engine", subtitle: engineDetail) {
                    StatusChip(text: engineLabel, tone: app.voice.status == .kokoro ? .green : .amber)
                }
                SettingRow(title: "Kokoro voice", detail: "Used for English. Spanish and French use Kokoro's own voices.") {
                    Picker("", selection: $settings.voiceName) {
                        ForEach(app.voice.voices.isEmpty ? [settings.voiceName] : app.voice.voices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 180).disabled(app.voice.status != .kokoro)
                }
                SettingRow(title: "Speed") {
                    Slider(value: $settings.voiceSpeed, in: 0.7...1.4, step: 0.05).frame(width: 220)
                }
            }
        }
    }

    private var engineLabel: String {
        switch app.voice.status {
        case .off: "Off"
        case .starting: "Starting"
        case .kokoro: "Kokoro"
        case .system: "macOS voice"
        }
    }

    private var engineDetail: String? {
        if case .system(let reason) = app.voice.status { return reason }
        return app.voice.status == .kokoro ? "Kokoro-82M, running on this Mac." : nil
    }
}
