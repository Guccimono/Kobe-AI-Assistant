import SwiftUI
import KobeKit

struct MacStep: View {
    let name: String

    var body: some View {
        StepHeading(title: "What \(name) can see on this Mac.",
                    lead: "Each one asks macOS for permission the first time you open its page, not now. You can say no to any of them.")
        LazyVGrid(columns: twoColumns, spacing: 10) {
            InfoCard(title: "Mail", detail: "Unread count and the latest messages. Never sends.")
            InfoCard(title: "Calendar", detail: "Today and the month. Opens events in Calendar.")
            InfoCard(title: "Reminders", detail: "What's due; add one from the notch; tick when you click.")
            InfoCard(title: "Notes", detail: "Recent notes; edit one in the notch.")
        }
        MutedLine("The engine reads them through Kobe, on your Mac. Nothing is uploaded unless you ask \(name) something about it.")
            .padding(.top, 14)
    }
}
