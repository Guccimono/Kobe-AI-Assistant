import AppKit
import SwiftUI
import KobeKit

/// WhatsApp (spec §6.2): the chat list from the snapshot, unread rows tinted green with their count; Return opens
/// the conversation in place (`WhatsAppConversation`, its messages from the in-app controller). "Mark all read"
/// waits 5 s with an undo before it goes; nothing is marked read by just looking (unless Settings says so on open).
struct WhatsAppPage: View {
    let app: AppModel
    @State private var selection = PageSelection()
    @State private var searching = false
    @State private var query = ""
    @State private var undo: UUID?

    private var wa: WhatsAppController { app.whatsapp }

    var body: some View {
        Group {
            if let jid = app.whatsappChat, let conversation = wa.inbox.conversations[jid] {
                WhatsAppConversation(app: app, conversation: conversation)
            } else {
                list
            }
        }
        .onDisappear { app.whatsappChat = nil }
    }

    // MARK: List

    private var list: some View {
        let chats = rows
        let unread = chats.reduce(0) { $0 + unreadCount($1) }
        return PageScaffold(app: app, id: .whatsapp,
                            chip: unread > 0 ? ("\(unread) unread", .ok) : nil,
                            footer: ["↩ opens", "⌘F search", "Esc closes"],
                            keys: listKeys(searching: searching),
                            onKey: { key(key: $0, chats: chats) }) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if searching {
                    PageSearchField(prompt: "Search chats", query: $query) {
                        if let chat = selection.current(in: chats) ?? chats.first { open(chat) }
                    }
                }
                if chats.isEmpty {
                    Text(query.isEmpty ? "No new messages" : "No chat matches \u{201C}\(query)\u{201D}")
                        .font(KFont.body).foregroundStyle(K.text2).padding(.horizontal, 2)
                } else {
                    PageList(app: app, selected: selection.current(in: chats)?.jid) {
                        VStack(spacing: 2) {
                            ForEach(Array(chats.enumerated()), id: \.element.jid) { index, chat in
                                row(chat, focused: selection.index == index).id(chat.jid)
                            }
                        }
                    }
                }
            }
            .onChange(of: chats.count) { _, count in selection.clamp(count: count) }
        } actions: {
            if let undo, let failure = app.actionQueue.failures[undo] {
                // Refused after the undo window: the rows are unread again, and this says why.
                Button { app.actionQueue.dismissFailure(undo); self.undo = nil } label: {
                    Text("Couldn't mark read: \(failure)").font(KFont.meta).foregroundStyle(K.red).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            } else if let undo {
                UndoChip(text: "Marked read") { if app.actionQueue.undo(undo) { self.undo = nil } }
                    .id(undo)
            }
            Button("Mark all read") { markAllRead(chats) }
                .buttonStyle(GlassButtonStyle())
                .disabled(unread == 0)
            if WhatsAppController.appURL != nil {
                Button("Open WhatsApp") { wa.openWhatsAppApp() }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    /// The snapshot's chats, narrowed by the search (name or preview).
    private var rows: [WhatsAppSnapshotChat] {
        let chats = app.snapshots.whatsapp?.data.chats ?? []
        guard searching else { return chats }
        return chats.filter { PageSearch.matches(query, [$0.name, $0.preview]) }
    }

    /// A chat waiting out its "Mark read" undo already shows as read.
    private func unreadCount(_ chat: WhatsAppSnapshotChat) -> Int {
        let pending = app.actionQueue.waiting.contains(.whatsappMarkRead(chat: chat.jid))
        return pending ? 0 : chat.unread
    }

    private func row(_ chat: WhatsAppSnapshotChat, focused: Bool) -> some View {
        let unread = unreadCount(chat)
        let tint = StripLayout.tint(.whatsapp).color
        return KitRow(title: chat.name, detail: Self.preview(chat), meta: WAText.timeAgo(chat.last),
                      tint: unread > 0 ? tint : nil, focused: focused) {
            WhatsAppAvatar(name: chat.name, isGroup: chat.isGroup)
        } trailing: {
            if unread > 0 {
                Text(WAText.unreadBadge(unread)).font(KFont.meta.weight(.bold)).monospacedDigit()
                    .foregroundStyle(K.window)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(tint, in: Capsule())
                    .fixedSize()
            }
        } action: {
            open(chat)
        }
        .contextMenu {
            if unread > 0 { Button("Mark read") { undo = app.actionQueue.schedule([.whatsappMarkRead(chat: chat.jid)]) } }
            Button("Ignore this chat") { wa.ignore(chat.jid) }
        }
    }

    /// The preview as the phone shows it: "You:" dimmed, an @mention of you in WhatsApp green.
    static func preview(_ chat: WhatsAppSnapshotChat) -> Text {
        var rest = Substring(chat.preview)
        var text = Text(verbatim: "")
        let you = WAText.you + ": "
        if rest.hasPrefix(you) {
            text = Text(verbatim: you).foregroundStyle(K.text3)
            rest = rest.dropFirst(you.count)
        }
        guard chat.mentionsMe else { return Text("\(text)\(Text(verbatim: String(rest)))") }
        for (i, word) in rest.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let piece = (i > 0 ? " " : "") + word
            // Text interpolation, not `+` (deprecated in macOS 26); each piece keeps its own style.
            let styled = word.hasPrefix("@")
                ? Text(verbatim: piece).foregroundStyle(StripLayout.tint(.whatsapp).color).fontWeight(.semibold)
                : Text(verbatim: piece)
            text = Text("\(text)\(styled)")
        }
        return text
    }

    // MARK: Actions

    private func key(key: PageKey, chats: [WhatsAppSnapshotChat]) {
        switch key {
        case .up: selection.move(.up, count: chats.count)
        case .down: selection.move(.down, count: chats.count)
        case .enter: if let chat = selection.current(in: chats) { open(chat) }
        case .search:
            searching = true
        case .escape:
            // Esc closes the search first; the next one goes Home.
            searching = false
            query = ""
        case .refresh, .left, .right, .hide: break
        }
    }

    private func open(_ chat: WhatsAppSnapshotChat) {
        // Only a chat the controller has (the shim's own inbox) opens; Kobe Agent's list alone has no messages.
        guard wa.inbox.conversations[chat.jid] != nil else { return }
        searching = false
        query = ""
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { app.whatsappChat = chat.jid }
    }

    private func markAllRead(_ chats: [WhatsAppSnapshotChat]) {
        let actions = chats.filter { unreadCount($0) > 0 }.map { WidgetAction.whatsappMarkRead(chat: $0.jid) }
        guard !actions.isEmpty else { return }
        undo = app.actionQueue.schedule(actions)
    }
}

/// Initials on WhatsApp green, the group icon for groups: no photo is ever fetched (they live on WhatsApp's
/// servers).
struct WhatsAppAvatar: View {
    let name: String
    let isGroup: Bool
    var size: CGFloat = 24

    var body: some View {
        let tint = StripLayout.tint(.whatsapp).color
        ZStack {
            Circle().fill(tint.opacity(0.22))
            if isGroup {
                Icon(icon: .usersThreeFill, size: size * 0.5).foregroundStyle(tint)
            } else {
                Text(verbatim: WAJID.initials(name)).font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}
