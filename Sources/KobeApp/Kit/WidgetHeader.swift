import SwiftUI
import KobeKit

/// Service dot, name, optional status chip, and freshness/source meta pushed right. The tint is the service's
/// colour and appears only here and on its accent rows.
struct WidgetHeader: View {
    let tint: Color
    let name: String
    var chip: ChipTone?
    var chipText: String?
    let meta: String
    var metaTone: ChipTone = .neutral

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(name).font(KFont.title).foregroundStyle(K.text1)
            if let chip, let chipText { StatusChip(text: chipText, tone: chip) }
            Spacer(minLength: Spacing.sm)
            Text(meta).font(KFont.meta)
                .foregroundStyle(metaTone == .neutral ? K.text3 : metaTone.color).lineLimit(1)
        }
    }
}

#Preview {
    WidgetHeader(tint: K.green, name: "WhatsApp", chip: .ok, chipText: "6 unread", meta: "updated 2 min ago · Kobe")
        .padding().background(.black)
}
