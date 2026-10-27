import SwiftUI
import KobeKit

struct ReadyStep: View {
    let name: String

    var body: some View {
        StepHeading(title: "That's it.", lead: lead)
        HStack {
            Spacer()
            (Text(name).fontWeight(.bold).foregroundStyle(K.lime) + Text(" · 3 need you · Ana paid €40 · Standup in 20 min"))
                .font(KFont.secondary).foregroundStyle(K.text3)
                .frame(width: 420, height: 110)
                .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous))
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
                    .strokeBorder(K.hairline, lineWidth: 1))
            Spacer()
        }
        .padding(.top, 12)
        LazyVGrid(columns: twoColumns, spacing: 10) {
            InfoCard(title: "Writing first",
                     detail: "Home opens on the chat; typing folds the Now list to a rail. ⌘\\ brings it back.")
            InfoCard(title: "Nothing happens without you",
                     detail: "Approvals, WhatsApp replies and anything that costs money need a click or a hotkey from you.")
        }
        .padding(.top, 16)
    }

    private var lead: Text {
        Text("Move the pointer to the notch to open \(name). From any app, ")
            + Text("⌃⌥Space").font(KFont.row.monospaced()).foregroundStyle(K.text1)
            + Text(" asks a quick question.")
    }
}
