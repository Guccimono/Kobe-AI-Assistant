import AppKit
import SwiftUI
import KobeKit

/// One conversation on the WhatsApp page (spec §6.2): back, the contact with its number masked, the last 20
/// messages, and the reply field. Return sends (⇧Return a new line), Esc goes back to the list keeping the draft.
/// A reply goes only from the user's own Return or click, through the `ActionSink`; it can't be taken back once
/// sent, so there is no undo: "Sent" once it went, or the reason in place with the text kept.
struct WhatsAppConversation: View {
    let app: AppModel
    let conversation: WAConversation
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var wa: WhatsAppController { app.whatsapp }
    private var jid: String { conversation.id }

    private var draft: Binding<String> {
        Binding(get: { wa.drafts[jid] ?? "" }, set: { wa.drafts[jid] = $0.isEmpty ? nil : $0 })
    }

    private var draftIsEmpty: Bool { draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        PageScaffold(app: app, id: .whatsapp, chip: nil, footer: footer, keys: [.escape], onKey: { key in
            if key == .escape { back() }
        }) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                header
                messages
                field
                if let line = statusLine {
                    Text(verbatim: line.text).font(KFont.secondary).foregroundStyle(line.color).lineLimit(2)
                }
            }
        } actions: {
            EmptyView()
        }
        .onAppear {
            wa.open(jid)
            focused = true
        }
        .onChange(of: draft.wrappedValue) { _, text in
            wa.hasDraft = WhatsAppController.isDraft(text)
            if !text.isEmpty { sent = false }
        }
        // `open` holds the island for a saved draft, `close` lets it go.
        .onDisappear { wa.close(jid) }
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Icon(icon: .caretLeft, size: 13)
                    Text("Chats").font(KFont.row)
                }
                .foregroundStyle(K.text2)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(K.glass, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Back to the chats (Esc)")
            WhatsAppAvatar(name: conversation.name, isGroup: conversation.isGroup, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.name).font(KFont.row).foregroundStyle(K.text1).lineLimit(1)
                if let number = WAJID.masked(jid) {
                    Text(verbatim: number).font(KFont.meta).foregroundStyle(K.text3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var messages: some View {
        let shown = Array(conversation.messages.suffix(WAInbox.keep))
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { message in
                        WhatsAppBubble(message: message, isGroup: conversation.isGroup).id(message.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if let last = shown.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            .onChange(of: shown.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        // The page fits its content: the messages get an explicit height from the island's resizable one.
        .frame(height: max(160, min(320, app.island.contentHeight - 250)))
    }

    private var field: some View {
        let tint = StripLayout.tint(.whatsapp).color
        return HStack(alignment: .bottom, spacing: Spacing.sm) {
            TextField(WAText.replyPlaceholder, text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(KFont.body).foregroundStyle(K.text1)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(submit)
                .shiftReturnAddsLine()
                .disabled(sending)
                .padding(.vertical, 8)
            Button(action: send) {
                Icon(icon: .arrowUp, size: 15).foregroundStyle(draftIsEmpty || sending ? K.text3 : tint)
                    .frame(width: 28, height: 28).background(K.glass, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(draftIsEmpty || sending)
            .help("Send (Return)")
            .padding(.bottom, 3)
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 1)
        .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
    }

    /// The link's state first (nothing can go while it's down), then the last send's outcome.
    private var statusLine: (text: String, color: Color)? {
        if wa.link != .connected { return (wa.link.label, K.amber) }
        if let error { return (error, K.red) }
        if sent { return ("Sent", K.green) }
        return nil
    }

    /// The limits before you hit them (spec §8), and which number the reply goes from.
    private var footer: [String] {
        var keys = ["↩ sends", "⇧↩ new line", "Esc back"]
        if let me = wa.me.flatMap(WAJID.masked) { keys.append("Sent as \(me)") }
        keys += ["4,096 characters max", "a few a minute"]
        return keys
    }

    private func back() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { app.whatsappChat = nil }
    }

    /// Return sends; ⇧Return starts a new line instead.
    private func submit() {
        if NSEvent.modifierFlags.contains(.shift) {
            draft.wrappedValue += "\n"
            focused = true
            return
        }
        send()
    }

    private func send() {
        let text = draft.wrappedValue
        guard !draftIsEmpty, !sending else { return }
        sending = true
        error = nil
        Task {
            let result = await app.actions.perform(.whatsappReply(chat: jid, text: text))
            sending = false
            switch result {
            case .success:
                // Only what was sent goes: a line typed meanwhile stays.
                if wa.drafts[jid] == text { wa.drafts[jid] = nil }
                sent = true
            case .failure(let failure):
                error = failure.message
            }
            focused = true
        }
    }
}

/// One message: theirs on the left, yours tinted WhatsApp green on the right; the copy button on hover.
struct WhatsAppBubble: View {
    let message: WAMessage
    let isGroup: Bool

    var body: some View {
        let (label, value) = message.preview
        let tint = StripLayout.tint(.whatsapp).color
        HStack(spacing: 0) {
            if message.fromMe { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 2) {
                if isGroup && !message.fromMe && !message.senderName.isEmpty {
                    Text(message.senderName).font(KFont.meta.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
                }
                if !label.isEmpty {
                    HStack(spacing: 5) {
                        Icon(icon: Self.icon(message.media), size: 13)
                        Text(verbatim: label)
                    }
                    .font(KFont.secondary.weight(.medium)).foregroundStyle(K.text2)
                }
                if !value.isEmpty {
                    Text(verbatim: value).font(KFont.body).foregroundStyle(message.fromMe ? K.text1 : K.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(message.fromMe ? tint.opacity(0.18) : K.glassActive,
                        in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
            .copyable(value.isEmpty ? label : value, trailing: !message.fromMe)
            if !message.fromMe { Spacer(minLength: 60) }
        }
    }

    private static func icon(_ media: WAMedia) -> PhosphorIcon {
        switch media {
        case .image: .image
        case .video: .videoCamera
        case .audio, .voice: .waveform
        case .document: .file
        case .sticker: .smiley
        case .location: .mapPin
        case .contact: .userCircle
        case .none, .other: .chatDots
        }
    }
}
