import AppKit
import SwiftUI
import KobeKit

/// Settings › Connections › WhatsApp (experimental), top to bottom. Off until turned
/// on; the gateway's address and credentials go to the Keychain; the QR to link WhatsApp shows right here.
struct WhatsAppSettingsSection: View {
    let app: AppModel
    @State private var showAdvanced = false
    @State private var gateway: WAGatewayKind
    @State private var url: String
    @State private var credential: String
    @State private var port: String
    @State private var respectFocus: Bool
    @State private var markReadOnOpen: Bool
    @State private var autoStart: Bool
    @State private var gowaPath: String
    @State private var testResult: String?
    @State private var testing = false
    @State private var ignoreEntry = ""

    init(app: AppModel) {
        self.app = app
        let settings = app.whatsapp.settings
        _gateway = State(initialValue: settings.gateway)
        _url = State(initialValue: settings.customURL ?? "")
        _credential = State(initialValue: settings.credential ?? "")
        _port = State(initialValue: String(settings.port))
        _respectFocus = State(initialValue: settings.respectFocus)
        _markReadOnOpen = State(initialValue: settings.markReadOnOpen)
        _autoStart = State(initialValue: settings.autoStart)
        _gowaPath = State(initialValue: settings.binaryPath)
    }

    private var wa: WhatsAppController { app.whatsapp }
    private var installer: WhatsAppGOWAInstaller { wa.installer }
    private var settings: WhatsAppSettings { wa.settings }

    var body: some View {
        Card(eyebrow: "Integration", title: "WhatsApp (experimental)", trailing: chip) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Unofficial integration: it goes through a gateway you run on this Mac. Use it on your own account only. WhatsApp may restrict accounts that abuse it.")
                    .font(KFont.secondary)
                    .foregroundStyle(WAColor.amber)
                    .fixedSize(horizontal: false, vertical: true)

                SettingRow(title: "Show my WhatsApp messages") {
                    toggle(Binding(get: { wa.enabled }, set: { wa.setEnabled($0) }))
                }

                if wa.enabled {
                    // One click: Kobe downloads GOWA, checks it and starts it. No Terminal.
                    if gateway == .gowa { installBlock }

                    if showsLinkState { linkState }

                    divider
                    SettingRow(title: "Mute groups (unless I’m mentioned)") {
                        toggle(Binding(get: { wa.filters.muteGroups }, set: { wa.filters.muteGroups = $0 }))
                    }
                    SettingRow(title: "Stay quiet during a Focus") {
                        toggle(Binding(get: { respectFocus }, set: { respectFocus = $0; wa.setRespectFocus($0) }))
                    }
                    if respectFocus && wa.focusReadable == false {
                        hint("macOS doesn’t let this build of Kobe read the Focus state yet: messages still arrive, Kobe keeps announcing them.")
                    }
                    SettingRow(title: "Mark as read when I open a conversation",
                               detail: "Off: marked read only when you reply. Never when a message just arrives.") {
                        toggle(Binding(get: { markReadOnOpen }, set: { markReadOnOpen = $0; wa.setMarkReadOnOpen($0) }))
                    }

                    divider
                    ignoredChats

                    divider
                    hint("Kobe only talks to the gateway on this Mac. Kobe keeps messages in memory only, never logs them, and forgets them when it quits; GOWA keeps its own chat history in its folder on this Mac. Ignored chats are remembered in Kobe's preferences. No photo or media is ever downloaded.")

                    // Your own gateway (OpenWA, another address, a password, the port): folded away.
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        advanced.padding(.top, 10)
                    } label: {
                        Text("Advanced: your own gateway").font(KFont.row).foregroundStyle(K.text1)
                    }
                    .tint(K.text2)
                }
            }
        }
        .onChange(of: installer.step) { _, step in
            // Installed by Kobe: the fields follow what it set.
            if case .done = step {
                gateway = .gowa
                url = ""
                autoStart = true
                gowaPath = settings.binaryPath
            }
        }
        .onChange(of: gateway) { old, new in
            // Still on the other gateway's default address: follow the switch.
            if url.isEmpty || url == old.defaultURL { url = new.defaultURL }
        }
    }

    // MARK: Pieces

    private var chip: AnyView? {
        guard wa.enabled else { return nil }
        let tone: ChipTone = switch wa.link {
        case .connected: .green
        case .connecting, .needsQR, .off: .amber
        default: .red
        }
        return AnyView(StatusChip(text: wa.link == .connected ? "Connected" : wa.link == .needsQR ? "Not linked" : wa.link == .off ? "Off" : wa.link == .connecting ? "Connecting" : "Problem", tone: tone))
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(K.lime)
    }

    private func hint(_ text: String, color: Color = WAColor.hint) -> some View {
        Text(verbatim: text)
            .font(KFont.secondary)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var divider: some View { Rectangle().fill(K.hairline).frame(height: 1) }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        Group {
            if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
        }
        .textFieldStyle(.plain)
        .font(KFont.body)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(K.panel2, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The status and QR once there is a gateway to talk to (before the install, "the gateway doesn't answer" would
    /// only confuse).
    private var showsLinkState: Bool {
        _ = wa.settingsVersion
        if gateway != .gowa || settings.isInstalled || !url.isEmpty { return true }
        return wa.link == .connected || wa.link == .needsQR
    }

    /// Install WhatsApp (GOWA) in one click, or its state once installed.
    @ViewBuilder private var installBlock: some View {
        let _ = wa.settingsVersion
        switch installer.step {
        case .checking, .downloading, .verifying, .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: installStepLabel).font(KFont.body).foregroundStyle(K.text1)
            }
        default:
            if settings.isInstalled {
                HStack(spacing: 8) {
                    Icon(icon: .checkCircleFill, size: 16).foregroundStyle(WAColor.accent)
                    Text(verbatim: settings.installedVersion.map { "Gateway GOWA \($0) installed, started by Kobe" }
                         ?? "Your GOWA gateway is set up")
                        .font(KFont.body).foregroundStyle(K.text1)
                    Spacer()
                    Button("Update") { installer.install() }.buttonStyle(GlassButtonStyle())
                }
            } else {
                Button { installer.install() } label: {
                    HStack(spacing: 6) {
                        Icon(icon: .arrowCircleDownFill, size: 16)
                        Text("Install WhatsApp")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                hint("Kobe downloads GOWA, the open-source gateway, from its GitHub page (about 15 MB, once), checks it and starts it. Then scan the QR code with your phone. No Terminal needed.")
            }
            if case .failed(let why) = installer.step {
                hint(why, color: WAColor.red)
            }
        }
    }

    private var installStepLabel: String {
        switch installer.step {
        case .checking: "Looking for the latest GOWA…"
        case .downloading(let mb): "Downloading (\(mb) MB)…"
        case .verifying: "Checking the download…"
        case .installing: "Installing and starting…"
        default: ""
        }
    }

    /// Linked or not, and the QR to scan when it's needed.
    @ViewBuilder private var linkState: some View {
        HStack(spacing: 6) {
            Circle().fill(WAColor.dot(wa.link)).frame(width: 6, height: 6)
            if wa.link == .connected, let me = wa.me {
                Text(verbatim: "Connected as \(WAJID.displayNumber(me))").font(KFont.body).foregroundStyle(K.text1)
            } else {
                Text(verbatim: wa.link.label).font(KFont.body).foregroundStyle(K.text1)
            }
            Spacer()
        }
        if wa.link == .connected {
            hint(webhookLine)
        }
        if wa.link == .needsQR {
            if let png = wa.qrPNG, let image = NSImage(data: png) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    hint("On your phone: WhatsApp › Settings › Linked devices › Link a device, then scan this code.")
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var webhookLine: String {
        switch wa.webhook {
        case .registered: "Live: new messages arrive at once."
        case .portBusy: "Port \(settings.port) is taken: pick another one. Checking every 20 s meanwhile."
        case .refused(let why): "The gateway refused Kobe’s address (\(why)). Checking every 20 s instead."
        case .off, .listening: "Checking for new messages every 20 s."
        }
    }

    @ViewBuilder private var ignoredChats: some View {
        Text("Ignored chats").font(KFont.row).foregroundStyle(K.text1)
        ForEach(wa.filters.ignored.sorted(), id: \.self) { chat in
            HStack(spacing: 6) {
                Text(verbatim: wa.inbox.conversations[chat]?.name ?? WAJID.displayNumber(chat))
                    .font(KFont.body).foregroundStyle(K.text2)
                Spacer()
                Button("Remove") { wa.unignore(chat) }.buttonStyle(GlassButtonStyle())
            }
        }
        HStack(spacing: 8) {
            field("Phone number or chat id to ignore", text: $ignoreEntry)
                .onSubmit(addIgnored)
            Button("Add", action: addIgnored)
                .buttonStyle(GlassButtonStyle())
                .disabled(ignoreEntry.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addIgnored() {
        guard let chat = WAJID.ignoreEntry(ignoreEntry) else { return }
        wa.ignore(chat)
        ignoreEntry = ""
    }

    // MARK: Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: "Gateway") {
                Picker("", selection: $gateway) {
                    ForEach(WAGatewayKind.allCases, id: \.self) { kind in Text(verbatim: kind.name).tag(kind) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            field(gateway.defaultURL, text: $url)
            field(gateway == .gowa ? "Basic auth  (user:password, if set)" : "API key  (owa_k1_…)", text: $credential, secure: true)
            if gateway == .gowa { autoStartRow }
            SettingRow(title: "Kobe’s webhook port") {
                field(String(WhatsAppSettings.defaultPort), text: $port).frame(width: 100)
            }
            HStack(spacing: 8) {
                Button("Save WhatsApp") { save() }.buttonStyle(PrimaryButtonStyle())
                Button("Test connection") {
                    save()
                    testing = true
                    Task {
                        testResult = await wa.testConnection()
                        testing = false
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(testing)
                if testing { ProgressView().controlSize(.small) }
            }
            if let testResult { hint(testResult) }
        }
    }

    /// Kobe starts the GOWA binary itself.
    @ViewBuilder private var autoStartRow: some View {
        SettingRow(title: "Start GOWA automatically") {
            toggle(Binding(get: { autoStart }, set: { on in
                autoStart = on
                settings.autoStart = on
                wa.settingsChanged()
            }))
        }
        if autoStart {
            HStack(spacing: 8) {
                field("Path to the GOWA binary (whatsapp)", text: $gowaPath)
                    .onSubmit(savePath)
                Button("Choose…") { chooseBinary() }.buttonStyle(GlassButtonStyle())
            }
            hint("Kobe runs it on this Mac only (127.0.0.1, the URL’s port), without downloading media, and stops it when Kobe quits. Its WhatsApp session stays in ~/Library/Application Support/Kobe/GOWA.")
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        gowaPath = url.path
        savePath()
    }

    private func savePath() {
        settings.binaryPath = gowaPath
        gowaPath = settings.binaryPath
        wa.settingsChanged()
    }

    private func save() {
        settings.setSecret(WhatsAppSettings.urlKey, url)
        settings.setSecret(WhatsAppSettings.credentialKey, credential)
        settings.gateway = gateway
        settings.binaryPath = gowaPath
        gowaPath = settings.binaryPath
        if let p = Int(port.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p) { settings.port = p }
        port = String(settings.port)
        wa.settingsChanged()
    }
}

/// WhatsApp's own green and greys, for the WhatsApp section of Settings (the page uses the kit).
enum WAColor {
    static let accent = RGB(0x25D366).color
    static let title = RGB(0xF5F6F8).color
    static let muted = RGB(0x6B7079).color
    static let hint = RGB(0x8E939C).color
    static let readName = RGB(0x9398A1).color
    static let unreadName = RGB(0xE8E9EC).color
    static let readPreview = RGB(0x4D5159).color
    static let theirText = RGB(0xC5C8CD).color
    static let onAccent = RGB(0x0B0C0E).color
    static let green = RGB(0x22C55E).color
    static let amber = RGB(0xF5B83D).color
    static let red = RGB(0xF4505E).color

    /// The link's dot, in the card and in Settings.
    static func dot(_ link: WhatsAppController.Link) -> Color {
        switch link {
        case .connected: green
        case .connecting, .needsQR: amber
        case .off: muted
        default: red
        }
    }
}
