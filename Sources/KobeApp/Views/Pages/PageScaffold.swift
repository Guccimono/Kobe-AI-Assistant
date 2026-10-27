import AppKit
import SwiftUI
import KobeKit

/// Every connection page (spec §6): `WidgetHeader`, an amber line when the last refresh or read failed, the
/// content (or the "Not set up" state), then the `Footer` with the page's buttons. It owns the keyboard while on
/// screen: ⌘R refreshes here; ↑↓, Return, ⌘F and (when the page asks for it) Esc go to `onKey`; Esc otherwise
/// goes Home through the island's own handler.
struct PageScaffold<Content: View, Actions: View>: View {
    let app: AppModel
    let id: WidgetID
    /// Before the freshness in the meta: "4 projects", "shop.example.com".
    let context: String?
    /// Replaces the snapshot's headline chip ("6 unread").
    let chip: (text: String, tone: ChipTone)?
    let footer: [String]
    let keys: Set<PageKey>
    let onKey: (PageKey) -> Void
    /// False for a page drawn mostly from the app's own state (Kobe's work): no snapshot is no "Not set up".
    let needsSnapshot: Bool
    let content: Content
    let actions: Actions

    init(app: AppModel, id: WidgetID, context: String? = nil, chip: (text: String, tone: ChipTone)? = nil,
         footer: [String], keys: Set<PageKey> = [.up, .down, .enter], onKey: @escaping (PageKey) -> Void = { _ in },
         needsSnapshot: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.app = app; self.id = id; self.context = context; self.chip = chip; self.footer = footer
        self.keys = keys.union([.refresh]); self.onKey = onKey; self.needsSnapshot = needsSnapshot
        self.content = content(); self.actions = actions()
    }

    private var envelope: WidgetSnapshot<EmptyData>? { app.snapshots.envelopes[id] }
    private var notSetUp: Bool { needsSnapshot && (envelope == nil || envelope?.status == .notSetUp) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // The meta says "updated 2 min ago": redrawn every 30 s, only while the page is on screen.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let freshness = app.snapshots.freshness(id)
                let stale = if case .stale = freshness { true } else { false }
                WidgetHeader(tint: StripLayout.tint(id).color, name: StripLayout.name(id), chip: chipValue?.tone,
                             chipText: chipValue?.text,
                             meta: [context, needsSnapshot || envelope != nil ? SnapshotRules.metaText(freshness, source: app.settings.copy.name) : nil]
                                 .compactMap { $0 }.joined(separator: " · "),
                             metaTone: stale ? .needsYou : .neutral)
            }
            if let problem {
                Text(problem).font(KFont.secondary).foregroundStyle(K.amber).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if notSetUp {
                NotSetUpBlock(app: app, headline: envelope?.headline ?? "Not set up",
                              detail: envelope?.detail ?? "Add it in Settings")
            } else {
                content
            }
            HStack(spacing: Spacing.sm) {
                Footer(keys: footer)
                actions
            }
        }
        .padding(Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
        .pageKeys(app.pageKeys, keys) { key in
            if key == .refresh { app.refreshPage(id) } else { onKey(key) }
        }
    }

    private var chipValue: (text: String, tone: ChipTone)? {
        if let chip { return chip }
        guard let envelope else { return ("Not set up", .neutral) }
        return switch envelope.status {
        case .ok: (envelope.headline, .ok)
        case .needsYou: (envelope.headline, .needsYou)
        case .failed: (envelope.headline, .failed)
        case .notSetUp: (envelope.headline, .neutral)
        }
    }

    /// Spec §8: a failed connector keeps its last good data with "couldn't refresh at 14:28: <reason>".
    private var problem: String? {
        if let read = app.snapshots.readErrors[id] { return "The file " + read }
        guard let envelope, envelope.status == .failed else { return nil }
        let reason = envelope.error.map { ": \($0)" } ?? ""
        return "Couldn't refresh at \(pageClock.string(from: envelope.updatedAt))\(reason)"
    }
}

/// "14:28" in the problem line.
private let pageClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

/// Nothing to show yet: what the snapshot says, and the way to Settings.
private struct NotSetUpBlock: View {
    let app: AppModel
    let headline: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(headline).font(KFont.row).foregroundStyle(K.text1)
            Text(detail).font(KFont.secondary).foregroundStyle(K.text2)
            Button("Settings…") {
                app.closeSurface()
                SettingsWindow.show(app, page: .connections)
            }
            .buttonStyle(GlassButtonStyle())
        }
        .padding(.vertical, Spacing.xs)
    }
}

/// A page's rows: at their natural height up to what the island's height leaves, then they scroll and the
/// handle appears under them (drag it to make the island taller). The selected row is kept in view.
struct PageList<Content: View>: View {
    let app: AppModel
    var selected: String?
    @ViewBuilder let content: Content
    @State private var natural: CGFloat = 0

    var body: some View {
        // The island's resizable height minus the tab bar, header and footer around the list.
        let cap = max(160, app.island.contentHeight - 170)
        VStack(spacing: Spacing.xs) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
                }
                .frame(height: min(natural, cap))
                .onChange(of: selected) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
            if natural > cap {
                ResizeHandle(height: Double(app.island.contentHeight),
                             onLive: { app.controller?.liveResize($0) },
                             onCommit: { app.controller?.commitResize($0) },
                             onReset: { app.settings.notchHeight = 0 })
            }
        }
    }
}

/// ⌘F's field over a list page (WhatsApp, GitHub, Vercel): it takes the caret when it appears; Return opens the
/// selected row (or the first match), Esc closes it (the page claims Esc while it is open).
struct PageSearchField: View {
    let prompt: String
    @Binding var query: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Icon(icon: .magnifyingGlass, size: 13).foregroundStyle(K.text3)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain).font(KFont.body).foregroundStyle(K.text1)
                .focused($focused)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
        .onAppear { focused = true }
    }
}

/// The keys a list page claims: Esc too while its search is open (Esc closes the search first).
func listKeys(searching: Bool) -> Set<PageKey> {
    searching ? [.up, .down, .enter, .search, .escape] : [.up, .down, .enter, .search]
}

/// A small eyebrow over a group of rows ("Needs you", "Latest").
struct PageGroup: View {
    let title: String

    var body: some View {
        Text(title.uppercased()).font(KFont.eyebrow).tracking(0.63).foregroundStyle(K.text3)
            .padding(.horizontal, 2).padding(.top, Spacing.xs)
    }
}

/// Opens an https link (a payment, a PR, a deploy); anything else is ignored rather than handed to the system.
@MainActor
func openLink(_ string: String?) {
    guard let string, let url = URL(string: string), url.scheme == "https" else { return }
    NSWorkspace.shared.open(url)
}

// MARK: Tab bar

/// What a connection page adds to the tab bar, left of ✕: Stripe's period switch, ↻, ⌕ on the list pages
/// (WhatsApp, GitHub, Vercel), and ↗ (the service's site).
struct PageTabActions: View {
    let app: AppModel
    let id: WidgetID

    var body: some View {
        // The period is the shim's: Kobe Agent writes today's totals only.
        if id == .stripe, app.owner(.stripe) == .app { PeriodSwitch(app: app) }
        RefreshButton(app: app, id: id)
        if id == .whatsapp {
            KitIconButton(icon: .magnifyingGlass, help: "Search (⌘F)") { app.pageKeys.post(.search) }
        } else if let site = Self.site(id) {
            if id != .stripe {
                KitIconButton(icon: .magnifyingGlass, help: "Search (⌘F)") { app.pageKeys.post(.search) }
            }
            KitIconButton(icon: .arrowUpRight, help: "Open \(StripLayout.name(id))") { openLink(site) }
        }
    }

    static func site(_ id: WidgetID) -> String? {
        switch id {
        case .stripe: "https://dashboard.stripe.com/payments"
        case .github: "https://github.com/pulls"
        case .vercel: "https://vercel.com/dashboard"
        case .google: "https://analytics.google.com"
        default: nil
        }
    }
}

/// ↻: spins from the click until the page's snapshot is rewritten, or 20 s.
private struct RefreshButton: View {
    let app: AppModel
    let id: WidgetID

    var body: some View {
        // The work page's ↻ reloads the cron jobs from Hermes: it spins while that request is out.
        let spinning = id == .work ? app.jobsLoading : app.refreshes.isSpinning(id, current: app.snapshots.envelopes[id]?.updatedAt)
        let button = KitIconButton(icon: .arrowClockwise, help: spinning ? "Refreshing…" : "Refresh (⌘R)") {
            app.refreshPage(id)
        }
        // Frames only while it spins; the timeline goes away with the spin, so nothing ticks afterwards.
        if spinning {
            TimelineView(.animation) { context in
                button.rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
            }
        } else {
            button
        }
    }
}

/// Stripe's Today / 7 d / 30 d.
private struct PeriodSwitch: View {
    let app: AppModel
    var body: some View {
        HStack(spacing: 0) {
            ForEach(StripePeriod.allCases, id: \.self) { period in
                KitTab(title: period.title, selected: app.stripe.period == period.rawValue) { app.stripe.setPeriod(period) }
            }
        }
        .padding(2)
        .background(K.glass, in: Capsule())
    }
}
