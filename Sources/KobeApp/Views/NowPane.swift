import SwiftUI
import KobeKit

/// Home's right pane: what Kobe Agent ranked in `now.json`, or the shim's `NowRanker` list while that file is
/// missing or stale. Current event, Needs you, Clients; quiet connections don't appear. ↑↓ move a selection over
/// the rows (in that order) and Return runs the selected row's action, like on the pages.
struct NowPane: View {
    let app: AppModel
    @State private var selection = PageSelection()

    var body: some View {
        let (data, updatedAt) = content
        let rows = Self.rows(data)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Spacing.sm) {
                Text("NOW").font(KFont.eyebrow).tracking(0.6).foregroundStyle(K.text3)
                Text(NowRanker.meta(updatedAt: updatedAt, copy: app.settings.copy)).font(KFont.meta).foregroundStyle(K.text3).lineLimit(1)
                Spacer(minLength: Spacing.sm)
                WorkChip(app: app)
                // Widen Now (the chat folds to its rail) or bring the chat back; never while an approval waits.
                if app.island.homeMode == .reading {
                    KitIconButton(icon: .arrowsInSimple, help: "Show the chat (⌘\\)") { app.island.homeMode = .split }
                } else if !app.needsAnswer {
                    KitIconButton(icon: .arrowsOutSimple, help: "Expand Now") { app.foldChat() }
                }
            }
            .padding(.horizontal, 2).padding(.bottom, 2)
            if let current = data.current {
                NowRowView(app: app, row: current, highlight: K.amber, focused: focused(current, rows))
            }
            if !data.needsYou.isEmpty {
                group("Needs you")
                ForEach(data.needsYou, id: \.id) {
                    NowRowView(app: app, row: $0, highlight: K.amber, focused: focused($0, rows))
                }
            }
            if !data.clients.isEmpty {
                group("Clients")
                ForEach(data.clients, id: \.id) {
                    NowRowView(app: app, row: $0, highlight: nil, focused: focused($0, rows))
                }
            }
            if data.current == nil, data.needsYou.isEmpty, data.clients.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NowRanker.emptyCopy).font(KFont.body).foregroundStyle(K.text2)
                    if let brief = data.brief { Text(brief).font(KFont.secondary).foregroundStyle(K.text3) }
                }
                .padding(.horizontal, 2).padding(.top, Spacing.sm)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelSurface()
        .onChange(of: rows.count) { _, count in selection.clamp(count: count) }
        .pageKeys(app.pageKeys, [.up, .down, .enter]) { key in
            switch key {
            case .up: selection.move(.up, count: rows.count)
            case .down: selection.move(.down, count: rows.count)
            case .enter: if let row = selection.current(in: rows) { NowRowView.perform(row.action ?? .open, row: row, app: app) }
            default: break
            }
        }
    }

    /// The rows in the order they are drawn: the current event, Needs you, Clients.
    private static func rows(_ data: NowSnapshotData) -> [NowRow] {
        (data.current.map { [$0] } ?? []) + data.needsYou + data.clients
    }

    /// A row id can repeat across groups only by mistake; the first one drawn takes the selection.
    private func focused(_ row: NowRow, _ rows: [NowRow]) -> Bool {
        selection.index != nil && selection.index == rows.firstIndex { $0.id == row.id }
    }

    /// Kobe Agent's own list when it is fresh; otherwise the shim's (`AppModel.nowContent`).
    private var content: (NowSnapshotData, Date?) { app.nowContent }

    private func group(_ title: String) -> some View {
        Text(title).font(KFont.eyebrow).foregroundStyle(K.text3).padding(.horizontal, 2).padding(.top, 4)
    }
}

/// One Now row: the service dot, two lines, its action as a glass button. Needs-you rows get the amber 8 % tint.
private struct NowRowView: View {
    let app: AppModel
    let row: NowRow
    let highlight: Color?
    let focused: Bool

    var body: some View {
        KitRow(title: app.moneyText(row.title), subtitle: app.moneyText(row.detail), tint: highlight, focused: focused,
               stacked: true) {
            Circle().fill(StripLayout.tint(row.source).color).frame(width: 7, height: 7)
        } trailing: {
            if let action = row.action {
                Button(Self.label(action)) { Self.perform(action, row: row, app: app) }.buttonStyle(GlassButtonStyle())
            }
        } action: {
            Self.perform(row.action ?? .open, row: row, app: app)
        }
    }

    static func label(_ action: NowAction) -> String {
        switch action {
        case .open: "Open"
        case .reply: "Reply"
        case .visit: "Visit"
        case .review: "Review"
        case .done: "Done"
        case .allow: "Allow"
        }
    }

    /// Reply opens that chat's conversation on the WhatsApp page (the row id is "whatsapp:<jid>"), Visit and
    /// Review the row's link when it has one (https only), everything else the row's page.
    static func perform(_ action: NowAction, row: NowRow, app: AppModel) {
        switch action {
        case .reply:
            if row.source == .whatsapp, row.id.hasPrefix("whatsapp:") {
                app.openWhatsApp(chat: String(row.id.dropFirst("whatsapp:".count)))
            } else {
                app.openPage(.whatsapp)
            }
        case .visit, .review:
            if let link = row.url.flatMap(URL.init(string:)), link.scheme == "https" {
                NSWorkspace.shared.open(link)
            } else {
                app.openPage(row.source)
            }
        case .open, .done, .allow: app.openPage(row.source)
        }
    }
}

/// The way into Kobe's work: "2 running" while runs are going, else "Work".
private struct WorkChip: View {
    let app: AppModel

    var body: some View {
        // Every source the work page counts: the app's runs, Kobe Agent's, Claude Code sessions.
        let running = WorkFeed.runningCount(app.workSections(now: .now))
        Button { app.openPage(.work) } label: {
            StatusChip(text: running > 0 ? "\(running) running" : "Work", tone: running > 0 ? .ok : .neutral)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(app.settings.copy.work)
    }
}
