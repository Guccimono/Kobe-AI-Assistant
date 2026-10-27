import SwiftUI
import KobeKit

struct OnboardingRoot: View {
    let nav: OnboardingNav

    private static let titles = ["Welcome to Kobe", "Your assistant", "The engine", "The brain", "Connecting",
                                 "Your Mac", "Connections", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                step.padding(.horizontal, 22).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(width: 760, height: 560)
        .background(K.window)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Icon(icon: .sparkleFill, size: 28).foregroundStyle(K.lime)
            Text(Self.titles[nav.step.rawValue]).font(KFont.row).foregroundStyle(K.text1)
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Capsule().fill(s.rawValue <= nav.step.rawValue ? K.lime : K.glassActive).frame(width: 22, height: 4)
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(K.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Text(OnboardingMachine.hint(nav.step)).font(KFont.secondary).foregroundStyle(K.text3)
                Spacer()
                Button("Back") { nav.go(-1) }
                    .buttonStyle(.plain).font(KFont.row).foregroundStyle(K.text2)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .opacity(nav.step == .welcome ? 0 : 1).disabled(nav.step == .welcome)
                Button(OnboardingMachine.nextLabel(nav.step)) { nav.go(1) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!nav.canLeave).opacity(nav.canLeave ? 1 : 0.4)
            }
            .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 16)
        }
    }

    @ViewBuilder private var step: some View {
        switch nav.step {
        case .welcome: WelcomeStep()
        case .assistant: AssistantStep(app: nav.app)
        case .engine: EngineStep(app: nav.app)
        case .brain: BrainStep(nav: nav)
        case .connecting: ConnectingStep(nav: nav)
        case .mac: MacStep(name: nav.name)
        case .connections: ConnectionsStep(app: nav.app)
        case .ready: ReadyStep(name: nav.name)
        }
    }
}
