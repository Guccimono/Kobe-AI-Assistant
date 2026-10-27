import SwiftUI
import KobeKit

struct ConnectingStep: View {
    let nav: OnboardingNav
    @State private var pasting = false
    @State private var pasted = ""
    private var connect: ConnectService { nav.app.connect }

    var body: some View {
        let name = nav.name
        StepHeading(title: "Connecting \(name) to the engine.", lead: "Kobe does this part alone. Nothing to copy.")
            .task { if !nav.connected, !connect.busy { await connect.run(choice: nil) } }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ConnectLine.allCases, id: \.self) { line in
                row(line, name: name)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(K.panel, radius: Radius.islandSmall)
        if let hello = connect.hello {
            StatusRow(color: K.green, title: "\(name):", detail: hello) { EmptyView() }.padding(.top, 12)
        }
    }

    @ViewBuilder private func row(_ line: ConnectLine, name: String) -> some View {
        let state = connect.lines[line] ?? .pending
        HStack(alignment: .top, spacing: 10) {
            marker(state)
            VStack(alignment: .leading, spacing: 4) {
                lineText(line, name: name)
                switch state {
                case .failed(let message):
                    Text(message).font(KFont.secondary).foregroundStyle(K.red).fixedSize(horizontal: false, vertical: true)
                case .needsChoice(let message):
                    Text(message).font(KFont.secondary).foregroundStyle(K.amber).fixedSize(horizontal: false, vertical: true)
                    choice
                case .skipped(let message):
                    Text(message).font(KFont.secondary).foregroundStyle(K.text3).fixedSize(horizontal: false, vertical: true)
                case .needsAction(let message):
                    Text(message).font(KFont.secondary).foregroundStyle(K.amber).fixedSize(horizontal: false, vertical: true)
                    Button("Check again") { Task { await connect.run(choice: nil) } }
                        .buttonStyle(GlassButtonStyle()).disabled(connect.busy)
                case .done where line == .wrotePersonality && connect.profileAppliedBy == .session:
                    Text(ConnectService.personalityOnTop).font(KFont.secondary).foregroundStyle(K.text3)
                        .fixedSize(horizontal: false, vertical: true)
                case .running where line == .privateKey && connect.restarting:
                    Text(ConnectService.restartingNote).font(KFont.secondary).foregroundStyle(K.text3)
                        .fixedSize(horizontal: false, vertical: true)
                default: EmptyView()
                }
            }
        }
    }

    private func lineText(_ line: ConnectLine, name: String) -> Text {
        let body = KFont.body, muted = KFont.secondary
        switch line {
        case .gaveKey:
            return Text("Gave the engine your \(nav.app.settings.selectedBrain.label) key").font(body)
        case .installedSkill:
            return Text("Installed the Kobe skill into Hermes ").font(body)
                + Text("(so it can write your Now list, answer the notch, read your Mac)").font(muted).foregroundStyle(K.text3)
        case .privateKey:
            return Text("Created a private key between Kobe and the engine ").font(body)
                + Text("· kept in your Keychain, you'll never need it").font(muted).foregroundStyle(K.text3)
        case .wrotePersonality:
            return Text("Wrote \(name)'s personality").font(body)
        case .firstHello:
            return Text("First hello from \(name)").font(body)
        }
    }

    @ViewBuilder private func marker(_ state: LineState) -> some View {
        Group {
            switch state {
            case .done: Icon(icon: .checkCircleFill, size: 18).foregroundStyle(K.green)
            case .skipped: Icon(icon: .checkCircle, size: 18).foregroundStyle(K.text3)
            case .running: ProgressView().controlSize(.small)
            case .pending: Icon(icon: .circle, size: 18).foregroundStyle(K.text3)
            case .needsChoice, .needsAction: Icon(icon: .warningCircleFill, size: 18).foregroundStyle(K.amber)
            case .failed: Icon(icon: .warningCircleFill, size: 18).foregroundStyle(K.red)
            }
        }
        .frame(width: 18, height: 18)
    }

    @ViewBuilder private var choice: some View {
        HStack(spacing: 10) {
            Button("Paste the existing key") { pasting = true }.buttonStyle(GlassButtonStyle())
            Button("Create a new key for Kobe") { Task { await connect.run(choice: .rotate) } }
                .buttonStyle(GlassButtonStyle())
        }
        if pasting {
            HStack(spacing: 10) {
                OnboardingField(placeholder: "Paste the engine key", text: $pasted, secure: true).frame(maxWidth: 340)
                Button("Use this key") {
                    let key = KeyCheck.trimmed(pasted)
                    pasted = ""
                    pasting = false
                    Task { await connect.run(choice: .pasteExisting(key)) }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(pasted.isEmpty)
            }
        }
    }
}
