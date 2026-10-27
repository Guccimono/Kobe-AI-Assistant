import SwiftUI
import KobeKit

/// Kobe's work (spec §6.10): what Kobe is doing while you're not looking, and the home of every approval.
/// `WorkFeed` composes it from the app's own runs, the `work` snapshot, the cron jobs (read only while this page is
/// open: on appear and ↻) and the Claude Code socket. The request that can be answered is drawn first and in full,
/// above the list, so it is never scrolled away: ⌥⌘Y / ⌥⌘N answer it after the 0.3 s arming, and Allow's hotkey
/// waits until its whole text was seen (the cards' own rules, unchanged).
struct WorkPage: View {
    let app: AppModel
    @State private var selection = PageSelection()
    /// The request block Return brought into focus (lime border); a move of the selection clears it.
    @State private var focusedRequest: String?

    var body: some View {
        let sections = app.workSections(now: .now)
        let rows = WorkFeed.selectable(sections)
        let selected = selection.current(in: rows)?.id
        let running = WorkFeed.runningCount(sections)
        PageScaffold(app: app, id: .work, context: "runs, cron jobs, Claude Code",
                     chip: running > 0 ? ("\(running) running", .ok) : ("Nothing running", .neutral),
                     footer: footer, keys: [.up, .down, .enter],
                     onKey: { key in
                         switch key {
                         case .up: selection.move(.up, count: rows.count); focusedRequest = nil
                         case .down: selection.move(.down, count: rows.count); focusedRequest = nil
                         case .enter:
                             // Return never answers and never stops: it only brings a waiting request into focus.
                             if case .focusRequest(let id)? = selection.current(in: rows)?.returnAction { focusedRequest = id }
                         case .refresh, .search, .escape, .left, .right, .hide: break
                         }
                     },
                     needsSnapshot: false) {
            // The answerable requests: Kobe's approval (the same card as Home's) and the first Claude Code card.
            // Keyed by the request: a newer one gets a fresh text view, so its Allow lock starts over unseen.
            if let request = app.chats.pendingApproval {
                ApprovalCard(request: request, app: app).id(request.id)
                    .requestFocus(selected: selected == "request:\(AppModel.approvalWaitingID)",
                                  focused: focusedRequest == AppModel.approvalWaitingID)
            }
            if let card = app.claudeCard {
                ClaudeRequestBlock(card: card, app: app).id(card.id)
                    .requestFocus(selected: selected == "request:\(card.id.uuidString)", focused: focusedRequest == card.id.uuidString)
            }
            // "running · 40 s" counts seconds only while a run goes and the page is on screen; otherwise a minute.
            TimelineView(.periodic(from: .now, by: running > 0 ? 1 : 60)) { context in
                WorkList(app: app, sections: app.workSections(now: context.date), selected: selected)
            }
            .onChange(of: rows.count) { _, count in selection.clamp(count: count) }
        } actions: {
            EmptyView()
        }
        .onAppear { app.refreshWork() }
    }

    /// The keys that work right now: the hotkeys only while a request is on screen for them, Esc only while
    /// nothing waits (a waiting request keeps the notch open, so Esc does nothing then).
    private var footer: [String] {
        var keys = ["↑↓ move", "⌘R refresh"]
        if !app.needsAnswer { keys.append("Esc back") }
        if app.hotKeyTarget != nil { keys.append("⌥⌘Y / ⌥⌘N answer the request on screen") }
        return keys
    }
}

private extension View {
    /// A request block under the selection (glass border) or brought into focus by Return (lime border).
    func requestFocus(selected: Bool, focused: Bool) -> some View {
        overlay {
            if focused || selected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(focused ? K.lime : K.glassHighlight, lineWidth: focused ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The first Claude Code card when it waits for an answer, drawn like Kobe's approval card.
private struct ClaudeRequestBlock: View {
    let card: ClaudeCard
    let app: AppModel

    var body: some View {
        switch card.event {
        case .permission(let permission):
            block(tint: K.amber) { ClaudePermissionBody(permission: permission, app: app) }
        case .question(let question):
            block(tint: K.lime) { ClaudeQuestionBody(question: question, app: app) }
        default:
            EmptyView()
        }
    }

    private func block(tint: Color, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

/// The sections as rows. The answerable requests are already drawn in full above, so here only the queued ones show.
private struct WorkList: View {
    let app: AppModel
    let sections: [WorkSection]
    /// The selected row's id, for its highlight and to keep it scrolled into view.
    let selected: String?

    var body: some View {
        let shown = sections.compactMap { section -> WorkSection? in
            let rows = section.rows.filter { !($0.kind == .waiting && $0.answerable) }
            return rows.isEmpty ? nil : WorkSection(title: section.title, rows: rows)
        }
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if sections.isEmpty, app.jobsError == nil {
                Text(app.jobsLoading ? "Looking at what \(app.settings.copy.name) is doing…" : "Nothing running, nothing waiting, nothing scheduled")
                    .font(KFont.body).foregroundStyle(K.text2).padding(.horizontal, 2)
            }
            if !shown.isEmpty {
                PageList(app: app, selected: shown.flatMap(\.rows).contains { $0.id == selected } ? selected : nil) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown, id: \.title) { section in
                            PageGroup(title: section.title)
                            ForEach(section.rows) { row in WorkRowView(app: app, row: row, focused: row.id == selected).id(row.id) }
                        }
                    }
                }
            }
            if let error = app.jobsError {
                Text("Couldn't read the cron jobs: \(error)").font(KFont.secondary).foregroundStyle(K.amber)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

private struct WorkRowView: View {
    let app: AppModel
    let row: WorkRow
    let focused: Bool

    var body: some View {
        KitRow(title: row.title, subtitle: row.detail.isEmpty ? nil : row.detail, tint: nil, focused: focused) {
            Circle().fill(Self.color(row.kind)).frame(width: 7, height: 7)
        } trailing: {
            if case .agent(let id) = row.source, let error = app.stopErrors[id] {
                // The refusal stays in place of the meta, where the Stop was clicked.
                Text(error).font(KFont.meta).foregroundStyle(K.amber).lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
            } else {
                Text(row.meta).font(KFont.meta).foregroundStyle(row.kind == .waiting ? K.amber : K.text3)
            }
            if row.stoppable {
                Button("Stop") { stop() }.buttonStyle(DangerButtonStyle()).help("Stop this run")
            }
        } action: {}
    }

    private func stop() {
        switch row.source {
        case .app(let id): app.stopAppRun(id)
        case .agent(let id): app.stopAgentRun(id)
        default: break
        }
    }

    static func color(_ kind: WorkRow.Kind) -> Color {
        switch kind {
        case .running: K.lime
        case .waiting: K.amber
        case .scheduled: K.text3
        case .done: K.green
        }
    }
}
