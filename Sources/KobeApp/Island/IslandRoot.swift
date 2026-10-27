import SwiftUI
import KobeKit

/// The whole island: black shell; open, the icon bar and the current view.
struct IslandRoot: View {
    let app: AppModel
    @Bindable var island: IslandModel

    var body: some View {
        let phase = island.phase
        let size = island.bodySize(for: phase)
        let flare = island.flare(for: phase)
        let shape = IslandShape(width: size.width + 2 * flare, height: size.height, radius: island.bottomRadius(for: phase), flare: flare)
        let notch = island.geometry.notchSize

        // The window stays put; the island's size and corners animate inside it, and the content,
        // laid out at the island's (animated) size, fades in and out clipped by the same shape.
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            switch phase {
            case .resting:
                EmptyView()
            case .compact:
                BannerView(app: app, notchWidth: notch.width, height: notch.height)
                    .frame(width: size.width, height: notch.height)
                    .padding(.horizontal, flare)
                    .clipShape(shape)
                    .transition(Animations.contentIn(after: 0.26))
            case .expanded:
                OpenIsland(app: app, island: island, notchHeight: notch.height)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .padding(.horizontal, flare)
                    .clipShape(shape)
                    .transition(Animations.contentIn(after: 0.16))
            }
        }
        .frame(width: size.width + 2 * flare, height: size.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Animations.open, value: island.overlay)
        .animation(Animations.open, value: island.tab)
        .animation(Animations.open, value: island.fittedHeight)
    }
}

/// The open island: the tab bar, the current view; Home also gets the resize handle. Other views fit their content.
struct OpenIsland: View {
    let app: AppModel
    @Bindable var island: IslandModel
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if island.overlay == .quickAsk {
                Color.clear.frame(height: notchHeight)
                if let request = app.chats.pendingApproval {
                    ApprovalCard(request: request, app: app, maxBodyHeight: 90).padding(.horizontal, 14).padding(.bottom, 8)
                }
                QuickAskView(app: app).padding(.horizontal, 14).padding(.bottom, 14)
            } else {
                // Above the content: the strip's label hangs below the bar over the top of the view.
                IslandTabBar(app: app)
                    .frame(height: max(notchHeight, IslandModel.barHeight))
                    .padding(.horizontal, 12)
                    .zIndex(1)
                if island.usesFittedHeight {
                    // Measured at its natural height; the island takes exactly that.
                    VStack(spacing: 10) {
                        // The work page shows the approval in its own "Waiting for you": once on screen, not twice.
                        if let request = app.chats.pendingApproval, island.overlay != .page(.work) {
                            ApprovalCard(request: request, app: app).id(request.id)
                        }
                        content
                    }
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in Color.clear.preference(key: FittedHeightKey.self, value: proxy.size.height) })
                    .onPreferenceChange(FittedHeightKey.self) { height in
                        if abs(height - island.fittedHeight) > 0.5 { island.fittedHeight = height }
                    }
                    Spacer(minLength: 0)
                } else {
                    if let request = app.chats.pendingApproval, island.overlay == .chatsList {
                        ApprovalCard(request: request, app: app).padding(.horizontal, 16).padding(.bottom, 10)
                    }
                    content
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    ResizeHandle(height: Double(island.contentHeight),
                                 onLive: { app.controller?.liveResize($0) },
                                 onCommit: { app.controller?.commitResize($0) },
                                 onReset: { app.settings.notchHeight = 0 })
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch island.overlay {
        case .claude: ClaudeCardView(app: app)
        case .page(let id):
            switch id {
            case .now: HomeView(app: app)
            case .whatsapp: WhatsAppPage(app: app)
            case .stripe: StripePage(app: app)
            case .github: GitHubPage(app: app)
            case .vercel: VercelPage(app: app)
            case .google: GooglePage(app: app)
            case .work: WorkPage(app: app)
            case .mail: MailPage(app: app)
            case .notes: NotesPage(app: app)
            case .reminders: RemindersPage(app: app)
            case .agenda: AgendaPage(app: app)
            default: PlaceholderPage(id: id)
            }
        case .chatsList: ChatsList(app: app)
        case .quickAsk, .none: HomeView(app: app)
        }
    }
}

/// The kit tab bar: the connections strip on the left; on the right a connection page's own actions (period, ↻,
/// ↗ or ⌕), elsewhere keep awake, Settings and sound; then the pin (⌘P), and close always last.
struct IslandTabBar: View {
    let app: AppModel

    var body: some View {
        TabBar {
            Strip(app: app)
        } trailing: {
            if case .page(let id) = app.island.overlay, app.canRefresh(id) {
                PageTabActions(app: app, id: id)
            } else {
                appActions
            }
            KitIconButton(icon: app.island.pinned ? .pushPinFill : .pushPin,
                          help: app.island.pinned ? "Unpin (⌘P)" : "Pin open (⌘P)",
                          tint: app.island.pinned ? K.lime : nil) {
                app.controller?.togglePin()
            }
            KitIconButton(icon: .x, help: "Close") { app.closeSurface() }
        }
    }

    @ViewBuilder private var appActions: some View {
        KitIconButton(icon: app.keepAwake.isActive ? .sunFill : .sun,
                      help: app.keepAwake.isActive ? "Keep awake: \(app.keepAwake.statusText)" : "Keep awake for 1 h",
                      tint: app.keepAwake.isActive ? K.lime : nil) {
            app.toggleKeepAwake()
        }
        KitIconButton(icon: .gearSix, help: "Settings") {
            app.closeSurface()
            SettingsWindow.show(app)
        }
        KitIconButton(icon: app.settings.soundOn ? .speakerHigh : .speakerSlash, help: app.settings.soundOn ? "Sound on" : "Sound off") {
            app.settings.soundOn.toggle()
        }
    }
}

private struct FittedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The wings beside the notch. A notification: who it's from on the left, what it is on the right. Otherwise (on
/// hover) Kobe's state on the left and, on the right, keep awake, what's new on the pills, or "Click to open".
struct BannerView: View {
    let app: AppModel
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                if let banner = app.banner {
                    Icon(icon: banner.icon, size: 14).foregroundStyle(banner.tint)
                    Text(banner.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(K.text1).lineLimit(1)
                } else {
                    Icon(icon: .sparkleFill, size: 14).foregroundStyle(app.connection.isConnected ? K.lime : K.text3)
                    Text(app.settings.copy.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(K.text1)
                    Text(app.isBusy ? "Thinking…" : app.connection.isConnected ? "Ready" : "Offline")
                        .font(.system(size: 12)).foregroundStyle(K.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(width: IslandModel.bandWing, height: height)
            Color.clear.frame(width: notchWidth, height: height)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if let banner = app.banner {
                    Text(banner.detail).font(.system(size: 12, weight: banner.waiting ? .semibold : .regular))
                        .foregroundStyle(banner.waiting ? K.amber : K.text2).lineLimit(1)
                } else if app.keepAwake.isActive {
                    Icon(icon: .sunFill, size: 13).foregroundStyle(K.lime)
                    Text(app.keepAwake.statusText).font(.system(size: 12)).foregroundStyle(K.text2).lineLimit(1)
                } else if !app.serviceBadges.isEmpty {
                    Text(StripLayout.order.filter { app.serviceBadges[$0] != nil }.map(StripLayout.name).joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(K.text2).lineLimit(1)
                } else {
                    Text("Click to open").font(.system(size: 12)).foregroundStyle(K.text3)
                }
            }
            .padding(.trailing, 14)
            .frame(width: IslandModel.bandWing, height: height)
        }
    }
}
