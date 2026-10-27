import SwiftUI
import KobeKit

struct ConnectionsStep: View {
    let app: AppModel
    private static let googleDoc = URL(string: "https://github.com/guccimono/Kobe-AI-Assistant/blob/main/docs/google.md")!

    var body: some View {
        StepHeading(title: "Connect what you use.",
                    lead: "All optional, all later in Settings. Every key is read-only where the service allows it, and stays in your Keychain.")
        LazyVGrid(columns: twoColumns, spacing: 10) {
            card("Claude Code", "See your coding sessions and approve from the notch.", page: .claude)
            card("WhatsApp", "Unread chats, reply from the notch.", page: .connections)
            card("Stripe", "Money in, read-only key.", page: .connections)
            card("GitHub", "PRs that need you, red mains.", page: .connections)
            card("Vercel", "Deploys, failures.", page: .connections)
            InfoCard(title: "Google", detail: "Analytics and Search Console.") {
                HStack(spacing: 8) {
                    StatusChip(text: "Later", tone: .neutral)
                    Link("How", destination: Self.googleDoc).font(KFont.row).foregroundStyle(K.lime)
                }
            }
        }
    }

    private func card(_ title: String, _ detail: String, page: SettingsWindow.Page) -> some View {
        InfoCard(title: title, detail: detail) {
            Button("Set up") { SettingsWindow.show(app, page: page) }.buttonStyle(GlassButtonStyle())
        }
    }
}
