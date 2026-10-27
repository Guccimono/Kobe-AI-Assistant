import SwiftUI
import KobeKit

/// Mail: the inbox at a glance, unread first. Return or a click opens that message in Mail.
struct MailPage: View {
    let app: AppModel
    @State private var selection = PageSelection()

    var body: some View {
        let snapshot = app.snapshots.mail
        let messages = snapshot?.data.messages ?? []
        PageScaffold(app: app, id: .mail,
                     context: messages.isEmpty ? nil : "\(messages.count) message\(messages.count == 1 ? "" : "s")",
                     footer: ["↩ opens in Mail", "Esc back"],
                     onKey: { key in
                         switch key {
                         case .up: selection.move(.up, count: messages.count)
                         case .down: selection.move(.down, count: messages.count)
                         case .enter: if let m = selection.current(in: messages) { app.mac.openMail(m.id) }
                         default: break
                         }
                     }) {
            MacPageNotice(app: app, kind: .mail, closed: snapshot.map { $0.data.appRunning ? nil : $0.detail } ?? nil)
            if messages.isEmpty {
                Text("Inbox clear").font(KFont.body).foregroundStyle(K.text2).padding(.horizontal, 2)
            } else {
                PageList(app: app, selected: selection.current(in: messages)?.id) {
                    VStack(spacing: 2) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            MailRow(message: message, focused: selection.index == index) { app.mac.openMail(message.id) }
                                .id(message.id)
                        }
                    }
                }
                .onChange(of: messages.count) { _, count in selection.clamp(count: count) }
            }
        } actions: {
            Button("Open Mail") { app.mac.openApp(.mail) }.buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct MailRow: View {
    let message: MailMessage
    let focused: Bool
    let open: () -> Void

    var body: some View {
        let subject = Text(message.subject.isEmpty ? "(no subject)" : message.subject).foregroundStyle(K.text1)
        let preview = Text(message.preview.isEmpty ? "" : "  " + message.preview).foregroundStyle(K.text3)
        KitRow(title: MacBuilders.senderName(message.sender), detail: subject + preview,
               meta: PageText.when(message.at), tint: message.unread ? StripLayout.tint(.mail).color : nil,
               focused: focused, stacked: true) {
            // Unread: Mail's blue dot; read: the same room, empty.
            Dot(color: message.unread ? StripLayout.tint(.mail).color : .clear)
        } trailing: {
            EmptyView()
        } action: {
            open()
        }
    }
}

/// The amber line on a Mac page: the app is closed (showing what Kobe read last), or what stopped the read.
struct MacPageNotice: View {
    let app: AppModel
    let kind: MacKind
    let closed: String?

    var body: some View {
        // A refusal is already the scaffold's "Couldn't refresh" line; the rest show here.
        let problem = app.mac.problem[kind].flatMap { $0 == kind.deniedCopy ? nil : $0 }
        if let line = closed ?? problem {
            Text(line).font(KFont.secondary).foregroundStyle(K.amber).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
