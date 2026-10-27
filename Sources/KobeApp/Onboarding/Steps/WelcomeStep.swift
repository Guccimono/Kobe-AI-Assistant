import SwiftUI
import KobeKit

struct WelcomeStep: View {
    var body: some View {
        StepHeading(title: "An assistant that lives in your notch.",
                    lead: "Kobe shows your messages, calendar, money and code at the top of the screen, and you talk to it like a colleague. To do that it needs two things, and we set both up together in about five minutes.")
        LazyVGrid(columns: twoColumns, spacing: 10) {
            InfoCard(title: "1. An engine",
                     detail: "Hermes Agent runs on your Mac and does the work: reads, remembers, acts. Free and open source. If it isn't here yet, Kobe installs it with you.")
            InfoCard(title: "2. A brain",
                     detail: "An AI model the engine thinks with. You pick one; the best ones are paid by use, one runs on your Mac for free.")
        }
        MutedLine("Nothing leaves your Mac except what you send to the brain you choose. No account with us, no telemetry.")
            .padding(.top, 14)
    }
}
