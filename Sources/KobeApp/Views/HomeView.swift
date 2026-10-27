import SwiftUI
import KobeKit

/// Home: the Kobe Agent chat on the left, "Now" on the right (spec §6.1, comfortable). Writing first: Now folds to a
/// 44 pt rail while typing (⌘\, a click or Esc brings it back); the chat's fold button gives Now the width.
struct HomeView: View {
    let app: AppModel

    var body: some View {
        // The chat gets a little more room than Now (1.1 : 1, the approved mockup).
        let width = app.island.openWidth - 32 - Spacing.md
        let mode = app.island.homeMode
        // The same ChatView and NowPane whatever the mode (only their frames change): folding Now while typing
        // must not rebuild the composer, or the caret is lost on the first letter.
        HStack(alignment: .top, spacing: Spacing.md) {
            if mode == .reading {
                ChatRail(app: app).frame(width: 44)
            } else {
                ChatView(app: app)
                    .frame(width: mode == .split ? (width * 1.1 / 2.1).rounded() : nil)
                    .frame(maxWidth: mode == .writing ? .infinity : nil)
            }
            if mode == .writing {
                NowRail(app: app).frame(width: 44)
            } else {
                NowPane(app: app).frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// The folded chat: the lime dot; a click (or ⌘\) unfolds it. An amber badge says something waits in the chat
/// (an approval, refused files) in case it is still folded.
private struct ChatRail: View {
    let app: AppModel

    var body: some View {
        Button { app.island.homeMode = .split } label: {
            VStack {
                Circle().fill(K.lime).frame(width: 8, height: 8).padding(.top, 18)
                if HomeLayout.railBadge(needsAnswer: app.needsAnswer, dropPending: app.dropResult != nil) {
                    Badge(kind: .needsYou).padding(.top, Spacing.sm)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panelSurface()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show the chat (⌘\\)")
    }
}

/// Folded Now: the needs-you count in amber and the expand icon; a click, ⌘\\ or Esc brings Now back.
private struct NowRail: View {
    let app: AppModel

    var body: some View {
        let waiting = app.nowContent.0.needsYou.count
        Button { app.island.homeMode = .split } label: {
            VStack(spacing: Spacing.sm) {
                Icon(icon: .arrowsOutSimple, size: 14).foregroundStyle(K.text2).padding(.top, 16)
                if waiting > 0 {
                    Text("\(waiting)").font(KFont.meta.weight(.semibold)).foregroundStyle(K.amber)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panelSurface()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(waiting > 0 ? "\(waiting) waiting for you. Show Now (⌘\\)" : "Show Now (⌘\\)")
    }
}

/// The field: text, the quick-ask hint, ↑ send (lime when there is something to send). Return sends; ⇧Return or
/// ⌥Return adds a line. Files dropped anywhere on the island land here (the island is the drop target).
struct Composer: View {
    @Bindable var app: AppModel
    var placeholder: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            field
            if app.settings.returnHintsShown < 3 {
                Text("↩ sends · ⇧↩ new line").font(KFont.meta).foregroundStyle(K.text3).padding(.leading, 12)
            }
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: Spacing.sm) {
            TextField(placeholder ?? app.settings.copy.askOrDrop, text: $app.composerDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(KFont.body)
                .foregroundStyle(K.text1)
                .lineLimit(HomeLayout.composerLines(app.island.homeMode))
                .focused($focused)
                .onSubmit { app.send(app.composerDraft) }
                .shiftReturnAddsLine()
                .padding(.vertical, 8)
            Text("⌃⌥Space").font(KFont.meta).foregroundStyle(K.text3).padding(.bottom, 9)
                .help("Quick ask from any app")
            Button { app.send(app.composerDraft) } label: {
                Icon(icon: .arrowUp, size: 15).foregroundStyle(canSend ? K.lime : K.text3)
                    .frame(width: 28, height: 28).background(K.glass, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(!canSend).help("Send").padding(.bottom, 3)
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 1)
        .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
        .limeHoverBorder(radius: Radius.tab)
        .disabled(!app.connection.isConnected)
        // Only a drop (or the menu's "Drop files…") asks for the caret: opening Home leaves the keyboard alone.
        .onAppear { focused = app.composerFocusPending; app.composerFocusPending = false }
        .onChange(of: app.composerDraft) { _, _ in if focused { app.composerTyped() } }
        .onChange(of: app.composerFocusPending) { _, pending in
            guard pending else { return }
            focused = true
            app.composerFocusPending = false
        }
    }

    private var canSend: Bool {
        app.connection.isConnected && !app.isBusy && !app.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
