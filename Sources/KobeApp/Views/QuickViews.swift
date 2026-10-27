import SwiftUI
import KobeKit

/// Quick ask (⌃⌥Space anywhere): one field, the answer below, "Open in chat". Drawn with the kit: the field is
/// Home's composer (glass, tab radius, lime ↑ when there is something to ask), the keys in the footer.
struct QuickAskView: View {
    @Bindable var app: AppModel
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Icon(icon: .lightning, size: 15).foregroundStyle(K.lime)
                TextField("Ask \(app.settings.copy.name) anything", text: $question)
                    .textFieldStyle(.plain).font(KFont.body).foregroundStyle(K.text1)
                    .focused($focused)
                    .onSubmit { app.quickAsk(question) }
                    .padding(.vertical, 8)
                Button { app.quickAsk(question) } label: {
                    Icon(icon: .arrowUp, size: 15).foregroundStyle(canAsk ? K.lime : K.text3)
                        .frame(width: 28, height: 28).background(K.glass, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(!canAsk).help("Ask")
            }
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 1)
            .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
            .limeHoverBorder(radius: Radius.tab)
            ScrollView {
                Group {
                    if app.quickAsking && app.quickAnswer.isEmpty {
                        Text(app.settings.copy.thinking).foregroundStyle(K.text3)
                    } else if !app.quickAnswer.isEmpty {
                        Text(app.quickAnswer).foregroundStyle(K.text1).textSelection(.enabled)
                    }
                }
                .font(KFont.body).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            HStack(spacing: Spacing.sm) {
                Footer(keys: ["↩ asks", "Esc closes"])
                Button { app.openQuickAskInChat() } label: {
                    HStack(spacing: 4) { Text("Open in chat"); Icon(icon: .arrowUpRight, size: 11) }
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(Spacing.md)
        .frame(maxHeight: .infinity, alignment: .top)
        .panelSurface()
        .onAppear { focused = true }
        .onExitCommand { app.closeSurface() }
    }

    private var canAsk: Bool {
        !app.quickAsking && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A row of pill segments; the selected one is filled.
struct Segmented: View {
    let options: [String]
    let selected: Int
    let choose: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                Button { choose(index) } label: {
                    Text(options[index]).font(.system(size: 13, weight: index == selected ? .semibold : .regular))
                        .foregroundStyle(index == selected ? Color.white : K.text3)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(index == selected ? K.panel2 : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Claude Code in the notch: finished, a permission, or a question.
struct ClaudeCardView: View {
    let app: AppModel

    var body: some View {
        if let card = app.claudeCard {
            Group {
                switch card.event {
                case .finished(let project, let appName):
                    HStack(spacing: 18) {
                        Icon(icon: .terminalWindowFill, size: 34).foregroundStyle(K.text2)
                        VStack(alignment: .leading, spacing: 4) {
                            header(color: .white, title: appName ?? project, detail: "Claude Code finished · \(project)")
                            Text("Session finished").font(.system(size: 20, weight: .bold)).tracking(-0.3).foregroundStyle(K.text1)
                            HStack(spacing: 10) {
                                Button("Open terminal") { app.openTerminal(for: card) }.buttonStyle(PrimaryButtonStyle())
                                Button("OK") { app.dismissClaude() }.buttonStyle(GlassButtonStyle())
                            }
                            .padding(.top, 8)
                        }
                        Spacer()
                    }
                case .permission(let permission):
                    HStack(alignment: .top, spacing: 18) {
                        Icon(icon: .shieldWarningFill, size: 34).foregroundStyle(K.amber)
                        // Keyed by the card: the next permission's text starts unseen, so its hotkey Allow locks again.
                        ClaudePermissionBody(permission: permission, app: app).id(card.id)
                        Spacer(minLength: 0)
                    }
                case .question(let question):
                    ClaudeQuestionBody(question: question, app: app)
                        .frame(maxWidth: .infinity, alignment: .leading)
                default:
                    EmptyView()
                }
            }
            .padding(22)
            .frame(maxHeight: .infinity, alignment: .top)
            .panelSurface()
        }
    }

    private func header(color: Color, title: String, detail: String) -> some View {
        ClaudeCardHeader(color: color, title: title, detail: detail)
    }
}

struct ClaudeCardHeader: View {
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 7) {
            Dot(color: color)
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(K.text1)
            Text("· \(detail)").font(.system(size: 13)).foregroundStyle(K.text3).lineLimit(1)
        }
    }
}

/// A Claude Code permission in full, with Allow / Deny / Answer in Claude: the Claude card and Kobe's work page
/// both draw it, so the lock and the hotkey hints are the same in both.
struct ClaudePermissionBody: View {
    let permission: ClaudePermission
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClaudeCardHeader(color: K.amber, title: "Claude Code", detail: "\(permission.title.lowercased()) · \(permission.project)")
            // The whole body, scrolling past 220 pt; a hotkey Allow waits until the end was seen.
            OverflowText(text: permission.body, font: .system(size: 14, design: .monospaced), color: Color(white: 0.9)) {
                app.reportClaudeLock($0, locked: $1)
            }
            if let detail = permission.detail { Text(detail).font(.system(size: 13)).foregroundStyle(K.text3) }
            HStack(spacing: 10) {
                Button { app.answerClaude(.allow) } label: {
                    HStack(spacing: 6) {
                        Text("Allow")
                        if !app.claudeAllowLocked { Text("⌥⌘Y").font(.system(size: 11)).foregroundStyle(.black.opacity(0.5)) }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .help(app.claudeAllowLocked ? "Scroll to the end of the request to allow it with ⌥⌘Y" : "Allow (⌥⌘Y)")
                Button { app.answerClaude(.deny) } label: {
                    HStack(spacing: 6) { Text("Deny"); Text("⌥⌘N").font(.system(size: 11)).foregroundStyle(K.text3) }
                }
                .buttonStyle(GlassButtonStyle())
                Button("Answer in Claude") { app.answerClaude(.none) }.buttonStyle(.plain)
                    .font(.system(size: 13)).foregroundStyle(K.text3)
            }
        }
    }
}

/// A Claude Code question with its options (or the way back to Claude Code when it asks several at once).
struct ClaudeQuestionBody: View {
    let question: ClaudeQuestion
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClaudeCardHeader(color: K.lime, title: "Claude Code", detail: "asks · \(question.project)")
            Text(question.question).font(.system(size: 18, weight: .bold)).foregroundStyle(K.text1)
            if question.count > 1 {
                // Several questions in one prompt: the notch can't answer them all, Claude Code asks.
                Text("Several questions at once: answer in Claude Code.").font(.system(size: 13)).foregroundStyle(K.text3)
                Button("Open Claude Code") { app.answerClaude(.none) }.buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            } else {
                FlowButtons(options: question.options) { app.answerClaude(.option($0)) }.padding(.top, 6)
                Button("Answer in Claude") { app.answerClaude(.none) }.buttonStyle(.plain)
                    .font(.system(size: 13)).foregroundStyle(K.text3).padding(.top, 4)
            }
        }
    }
}

/// One button per option; the first is the primary.
struct FlowButtons: View {
    let options: [String]
    let choose: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index == 0 {
                    Button(option) { choose(option) }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button(option) { choose(option) }.buttonStyle(GlassButtonStyle())
                }
            }
        }
    }
}
