import AppKit
import SwiftUI
import KobeKit

/// The Settings window: dark only, a sidebar and one page at a time.
@MainActor
enum SettingsWindow {
    enum Page: Hashable { case home, chats, statistics, connections, claude, general, keepAwake, voice, shortcuts, engine, brain, assistant }

    private static var window: NSWindow?
    static var isVisible: Bool { window?.isVisible == true }
    private static let selection = SettingsSelection()
    private static let delegate = WindowDelegate()

    static func show(_ app: AppModel, page: Page = .home) {
        selection.page = page
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRoot(app: app, selection: selection))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Kobe"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)
            window.setContentSize(NSSize(width: 1120, height: 760))
            window.minSize = NSSize(width: 900, height: 600)
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = delegate
            self.window = window
        }
        // While Settings is open, Kobe is a regular app: in the Dock and in ⌘Tab. Closing it hides Kobe again.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

/// Back to a menu-bar-only app once Settings closes.
final class WindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { if !OnboardingWindow.isVisible { _ = NSApp.setActivationPolicy(.accessory) } }
    }
}

/// The Settings window's current page (named apart from the notch pages' keyboard `PageSelection`).
@MainActor
@Observable
final class SettingsSelection {
    var page: SettingsWindow.Page = .home
}

struct SettingsRoot: View {
    let app: AppModel
    @Bindable var selection: SettingsSelection

    var body: some View {
        HStack(spacing: 18) {
            Sidebar(app: app, selection: selection)
            ScrollView {
                page.padding(.trailing, 6).padding(.vertical, 6)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 28).padding(.horizontal, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(K.window)
    }

    @ViewBuilder private var page: some View {
        switch selection.page {
        case .home: HomePage(app: app, selection: selection)
        case .chats: ChatsPage(app: app)
        case .statistics: StatisticsPage(app: app)
        case .connections: ConnectionsPage(app: app)
        case .claude: ClaudePage(app: app)
        case .general: GeneralPage(app: app)
        case .keepAwake: KeepAwakePage(app: app)
        case .voice: VoicePage(app: app)
        case .shortcuts: ShortcutsPage()
        case .engine: EnginePage(app: app)
        case .brain: BrainPage(app: app)
        case .assistant: AssistantPage(app: app)
        }
    }
}

struct Sidebar: View {
    let app: AppModel
    @Bindable var selection: SettingsSelection
    @State private var notchOpen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Icon(icon: .sparkleFill, size: 20).foregroundStyle(K.lime)
                Text("Kobe").font(.system(size: 21, weight: .bold)).foregroundStyle(K.text1)
            }
            .padding(.horizontal, 10).padding(.bottom, 18)
            item(.home, icon: .squaresFour, title: "Home")
            item(.chats, icon: .chatsCircle, title: "Chats", count: app.chats.sessions.count, tone: nil)
            item(.statistics, icon: .chartBar, title: "Statistics")
            item(.connections, icon: .plugsConnected, title: "Connections",
                 count: app.connections.filter { $0.status == .problem }.count, tone: .red)
            item(.claude, icon: .terminalWindowFill, title: "Claude Code")
            Button { notchOpen.toggle() } label: {
                HStack(spacing: 12) {
                    Icon(icon: .rectangle, size: 20)
                    Text("Notch").font(.system(size: 15, weight: .medium))
                    Spacer()
                    Icon(icon: notchOpen ? .caretUp : .caretDown, size: 13)
                }
                .foregroundStyle(K.text1).padding(.horizontal, 14).padding(.vertical, 11).contentShape(.rect)
            }
            .buttonStyle(.plain)
            if notchOpen {
                VStack(alignment: .leading, spacing: 2) {
                    subitem(.general, "General")
                    subitem(.keepAwake, "Keep awake")
                    subitem(.voice, "Voice")
                    subitem(.shortcuts, "Shortcuts")
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color(white: 0.16)).frame(width: 1) }
                .padding(.leading, 26)
            }
            item(.engine, icon: .plug, title: "Engine")
            item(.brain, icon: .sparkleFill, title: "Brain")
            item(.assistant, icon: .chatCircle, title: "Your assistant")
            Spacer()
            HStack(spacing: 8) {
                Dot(color: app.connection.isConnected ? K.green : K.red)
                Text(app.connection.isConnected ? "Connected · \(URL(string: app.settings.serverURL)?.host() ?? "")" : "Not connected")
                    .font(.system(size: 13)).foregroundStyle(K.text2).lineLimit(1)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface(K.panel, radius: 14)
        }
        .frame(width: 230)
    }

    private func item(_ page: SettingsWindow.Page, icon: PhosphorIcon, title: String, count: Int = 0, tone: ChipTone? = nil) -> some View {
        Button { selection.page = page } label: {
            HStack(spacing: 12) {
                Icon(icon: icon, size: 20)
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tone == .red ? Color.black : Color(white: 0.83))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(tone == .red ? K.red : K.panel3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .foregroundStyle(selection.page == page ? Color.white : K.text2)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(selection.page == page ? K.panel2 : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .limeHoverBorder(radius: 14)
    }

    private func subitem(_ page: SettingsWindow.Page, _ title: String) -> some View {
        Button { selection.page = page } label: {
            Text(title).font(.system(size: 14, weight: .medium))
                .foregroundStyle(selection.page == page ? Color.white : K.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(selection.page == page ? K.panel2 : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
