import SwiftUI
import KobeKit

/// The Kobe Agent chat, Home's left pane: the header (lime dot, Kobe, status, attach, talk), all chats, bubbles,
/// tool lines, the approval card and the field. A faint glow rises from the bottom while Kobe is thinking.
struct ChatView: View {
    let app: AppModel

    var body: some View {
        let foreign = app.chats.current.map { !$0.acceptsMessagesFromNotch } ?? false
        VStack(spacing: Spacing.sm) {
            ChatHeader(app: app)
            HStack(spacing: 8) {
                Button {
                    app.island.overlay = app.island.overlay == .chatsList ? .none : .chatsList
                } label: {
                    HStack(spacing: 6) { Icon(icon: .list, size: 12); Text("All chats").font(KFont.meta) }
                        .foregroundStyle(K.text2).padding(.horizontal, 9).padding(.vertical, 4)
                        .background(K.glass, in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).limeHoverBorder(radius: 999)
                Text(app.chats.current?.displayTitle ?? "New chat").font(KFont.meta).foregroundStyle(K.text3).lineLimit(1)
                Spacer()
            }
            if foreign, let place = app.chats.current?.sourceLabel(copy: app.settings.copy) {
                // Hermes keeps WhatsApp and CLI chats to their own app: read here, reply there.
                HStack(spacing: 6) {
                    Icon(icon: place == "WhatsApp" ? .whatsappLogoFill : .terminalWindowFill, size: 12)
                    Text("\(place) chat · read-only here. Writing starts a new chat.").font(KFont.secondary)
                }
                .foregroundStyle(K.amber)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(K.amber.opacity(0.1), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if app.chats.lines.isEmpty {
                            Text(app.chats.current?.displayTitle ?? app.settings.copy.newChat)
                                .font(KFont.secondary).foregroundStyle(K.text3).padding(.top, 24)
                        }
                        let calendar = Calendar.current
                        let dividers = ChatTimeline.dividers(app.chats.lines, calendar: calendar)
                        let lastUserID = app.chats.lastUserLine?.id
                        ForEach(app.chats.lines) { line in
                            if dividers.contains(line.id) {
                                DayDivider(label: ChatTimeline.label(line.at, now: .now, calendar: calendar))
                            }
                            MessageBubble(line: line, app: app, isLastUser: line.id == lastUserID)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .onChange(of: app.chats.lines.last?.text) {
                    if let last = app.chats.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let request = app.chats.pendingApproval {
                ApprovalCard(request: request, app: app).id(request.id)
            } else if let note = app.chats.approvalNote {
                Text(note == "Expired" ? "That request expired before it was answered." : note)
                    .font(KFont.secondary).foregroundStyle(K.text3).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let refused = app.dropResult?.refused, !refused.isEmpty {
                // What a drop couldn't copy; the copied files are already in the field.
                Button { app.dropResult = nil } label: {
                    Text("Not copied: " + refused.map { "\($0.name) (\($0.reason.message))" }.joined(separator: ", "))
                        .font(KFont.secondary).foregroundStyle(K.amber).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).help("Click to dismiss")
            }
            Composer(app: app, placeholder: foreign ? "Write to start a new chat…" : app.settings.copy.askOrDrop)
        }
        .padding(Spacing.md)
        .frame(maxHeight: .infinity)
        .background(alignment: .bottom) { if app.chats.isBusy { ThinkingGlow() } }
        .panelSurface()
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
    }
}

extension ChatView {
    /// The tool status ("searching the web…") shows only while Kobe is reachable and nothing waits on the user;
    /// otherwise the base text ("Waiting for you", "Offline") stays.
    static func headerText(status: String?, needsAnswer: Bool, connected: Bool, base: String) -> String {
        guard let status, !needsAnswer, connected else { return base }
        return status
    }
}

/// Lime dot · Kobe · "Ready · memory saved 4 min ago" · Stop while busy · ＋ attach · talk (not yet).
private struct ChatHeader: View {
    let app: AppModel

    var body: some View {
        let (color, base) = status
        let connected: Bool = if case .connected = app.connection.state { true } else { false }
        let text = ChatView.headerText(status: app.chats.status, needsAnswer: app.needsAnswer, connected: connected, base: base)
        let showsStatus = app.chats.status != nil && !app.needsAnswer && connected
        HStack(spacing: Spacing.sm) {
            Circle().fill(K.lime).frame(width: 8, height: 8)
            Text(app.settings.copy.name).font(KFont.title).foregroundStyle(K.text1)
            HStack(spacing: 0) {
                Text(text).foregroundStyle(showsStatus ? K.text2 : color).help(app.chats.model.map { "Model: \($0)" } ?? "")
                if let memory = app.snapshots.envelopes[.memory] {
                    // Only once Kobe Agent writes `memory.json`; it opens the memory page.
                    Button { app.openPage(.memory) } label: {
                        Text(" · memory saved " + SnapshotRules.ago(max(Date.now.timeIntervalSince(memory.updatedAt), 0)))
                            .foregroundStyle(K.text3)
                    }
                    .buttonStyle(.plain).help(app.settings.copy.memory)
                }
            }
            .font(KFont.meta).lineLimit(1)
            Spacer(minLength: Spacing.xs)
            if app.isBusy {
                Button("Stop") { app.chats.stop() }.buttonStyle(GlassButtonStyle())
            }
            KitIconButton(icon: .plus, help: "Attach files") { pickFiles() }
            KitIconButton(icon: .microphone, help: "Hold to talk — coming soon") {}
                .disabled(true).opacity(0.45)
            // Widen the chat (Now folds to its rail) or bring Now back; the same toggle as ⌘\.
            if app.island.homeMode == .writing {
                KitIconButton(icon: .arrowsInSimple, help: "Show Now (⌘\\)") { app.island.homeMode = .split }
            } else {
                KitIconButton(icon: .arrowsOutSimple, help: "Expand the chat (⌘\\)") { app.island.homeMode = .writing }
            }
        }
    }

    /// "Ready", "Thinking", "Waiting for you", "Offline", "Connect to Kobe in Settings".
    private var status: (Color, String) {
        if app.needsAnswer { return (K.amber, "Waiting for you") }
        switch app.connection.state {
        case .connected: return (K.text3, app.isBusy ? "Thinking" : "Ready")
        case .offline: return (K.red, "Offline")
        case .noKey: return (K.amber, "Connect to \(app.settings.copy.name) in Settings")
        case .unauthorized: return (K.red, "Key refused · check Settings")
        case .unknown: return (K.text3, "Connecting…")
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        _ = app.dropFiles(panel.urls)
    }
}

struct MessageBubble: View {
    let line: ChatLine
    let app: AppModel
    /// Whether this is the newest user line (it alone carries Edit and Retry); decided once by the chat.
    var isLastUser = false
    @State private var hovering = false

    var body: some View {
        switch line.role {
        case .user:
            HStack(spacing: 4) {
                Spacer(minLength: 60)
                if isLastUser { userActions.opacity(hovering ? 1 : 0) }
                Text(line.text).font(KFont.body).foregroundStyle(K.text1).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(K.lime.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
                    .copyable(line.text, trailing: false, caption: ChatTimeline.time(line.at, calendar: .current))
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        case .kobe:
            HStack {
                Text(markdown(line.text.isEmpty ? "…" : line.text)).font(KFont.body).lineSpacing(2)
                    .foregroundStyle(K.text1).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
                    .copyable(line.text, trailing: true, caption: ChatTimeline.time(line.at, calendar: .current))
                Spacer(minLength: 40)
            }
        case .tool:
            HStack(spacing: 6) {
                Icon(icon: .sparkleFill, size: 11)
                Text(line.text).font(.system(size: 12)).textSelection(.enabled)
                Spacer()
            }
            .foregroundStyle(K.text3)
        case .notice:
            Text(line.text).font(.system(size: 12)).foregroundStyle(K.amber).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Edit, and Retry after a failed or stopped turn, left of the last message while the pointer is over it.
    private var userActions: some View {
        HStack(spacing: 0) {
            KitIconButton(icon: .pencilSimple, help: "Edit") { app.editLastMessage() }
            if (app.chats.lastTurnEnded == .failed || app.chats.lastTurnEnded == .stopped), !app.chats.isBusy {
                KitIconButton(icon: .arrowClockwise, help: "Retry") { app.retryLastMessage() }
            }
        }
    }

    /// Inline Markdown; a link's destination host follows its text, "text (host)", so nothing is masked.
    private func markdown(_ text: String) -> AttributedString {
        guard var out = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        let links = out.runs.compactMap { run in run.link.map { (run.range, $0) } }
        for (range, url) in links.reversed() {
            let shown = String(out[range].characters)
            let host = url.host() ?? url.absoluteString
            guard !shown.localizedCaseInsensitiveContains(host) else { continue }
            var suffix = AttributedString(" (\(host))")
            suffix.foregroundColor = K.text3
            out.insert(suffix, at: range.upperBound)
        }
        return out
    }
}

/// Kobe needs a yes or no. Allow = this once; Deny = no. ⌥⌘Y / ⌥⌘N work from any app while it waits.
struct ApprovalCard: View {
    let request: ApprovalRequest
    let app: AppModel
    /// How tall the command may grow before it scrolls (less in the short quick ask island).
    var maxBodyHeight: CGFloat = 220

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Icon(icon: .warningCircleFill, size: 22).foregroundStyle(K.amber)
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(app.settings.copy.needsYou, color: K.amber)
                Text(ApprovalWording.summary(command: request.command, description: request.description))
                    .font(KFont.body).foregroundStyle(K.text1)
                if let command = request.command {
                    // The whole command, scrolling when long; a hotkey Allow waits until the end was seen.
                    OverflowText(text: command, font: .system(size: 13, design: .monospaced), color: Color(white: 0.85),
                                 lineHeight: 16, maxHeight: maxBodyHeight) { app.reportApprovalLock($0, locked: $1) }
                } else {
                    // Nothing long to read: the card itself is on screen, unlocked.
                    Color.clear.frame(width: 0, height: 0)
                        .modifier(AllowLockReporter(locked: false) { app.reportApprovalLock($0, locked: $1) })
                }
                Text(ApprovalWording.denyLine(copy: app.settings.copy)).font(KFont.meta).foregroundStyle(K.text3)
            }
            Spacer(minLength: 8)
            Button { app.answerApproval(.once) } label: {
                HStack(spacing: 6) {
                    Text("Allow")
                    if !app.approvalAllowLocked { Text("⌥⌘Y").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5)) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .help(app.approvalAllowLocked ? "Scroll to the end of the command to allow it with ⌥⌘Y" : "Allow (⌥⌘Y)")
            Button { app.answerApproval(.deny) } label: {
                HStack(spacing: 6) { Text("Deny"); Text("⌥⌘N").font(.system(size: 11)).foregroundStyle(K.text3) }
            }
            .buttonStyle(GlassButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(.sRGB, red: 0.094, green: 0.078, blue: 0.043), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(K.amber.opacity(0.35), lineWidth: 1))
    }
}

struct ThinkingGlow: View {
    var body: some View {
        RadialGradient(colors: [Color(.sRGB, red: 0.43, green: 0.43, blue: 0.82).opacity(0.32), .clear],
                       center: .bottom, startRadius: 0, endRadius: 260)
            .frame(height: 220)
            .allowsHitTesting(false)
    }
}

/// Every Hermes chat, newest first, with where it came from. Any can be opened and continued.
struct ChatsList: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { app.newChat() } label: {
                HStack(spacing: 10) { Icon(icon: .plus, size: 15); Text("New chat").font(.system(size: 14, weight: .semibold)); Spacer() }
                    .foregroundStyle(K.text1).padding(12).contentShape(.rect)
            }
            .buttonStyle(.plain).limeHoverBorder(radius: Radius.bubble)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(app.chats.sessions) { session in
                        HStack(spacing: 4) {
                            Button { app.openChat(session) } label: {
                                HStack(spacing: 10) {
                                    Text(session.displayTitle).font(.system(size: 14)).foregroundStyle(K.text1).lineLimit(1)
                                    Spacer()
                                    Text(session.sourceLabel(copy: app.settings.copy)).font(.system(size: 11, weight: .semibold)).foregroundStyle(K.text2)
                                        .padding(.horizontal, 8).padding(.vertical, 3).background(K.panel3, in: Capsule())
                                    if let when = session.lastActive {
                                        Text(Date(timeIntervalSince1970: when), style: .relative).font(.system(size: 12)).foregroundStyle(K.text3)
                                            .lineLimit(1).frame(width: 90, alignment: .trailing)
                                    }
                                }
                                .padding(.vertical, 12).padding(.leading, 12)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            DeleteChatButton { Task { await app.chats.delete(session) } }
                        }
                        .padding(.trailing, 6)
                        .background(session.id == app.chats.current?.id ? K.panel2 : .clear,
                                    in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                        .limeHoverBorder(radius: Radius.bubble)
                        .contextMenu {
                            Button("Delete chat", role: .destructive) { Task { await app.chats.delete(session) } }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .panelSurface()
        .task { await app.chats.refreshSessions() }
    }
}

/// The row's trash icon, confirmed in place: the first click turns it into a red Delete button, the second deletes.
/// It goes back to the trash icon after 3 s, or when the pointer leaves it.
private struct DeleteChatButton: View {
    let action: () -> Void
    @State private var hovering = false
    @State private var armed = false
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Button {
            if armed {
                disarm?.cancel()
                armed = false
                action()
            } else {
                withAnimation(.easeOut(duration: 0.15)) { armed = true }
                disarm = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.15)) { armed = false } }
                }
            }
        } label: {
            Group {
                if armed {
                    Text("Delete").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(K.red, in: Capsule())
                } else {
                    Icon(icon: .trash, size: 15)
                        .foregroundStyle(hovering ? K.red : K.text3)
                        .frame(width: 30, height: 30)
                        .background(hovering ? K.red.opacity(0.12) : .clear, in: Circle())
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if !inside, armed {
                disarm?.cancel()
                withAnimation(.easeOut(duration: 0.15)) { armed = false }
            }
        }
        .help(armed ? "Click again to delete" : "Delete chat")
    }
}
