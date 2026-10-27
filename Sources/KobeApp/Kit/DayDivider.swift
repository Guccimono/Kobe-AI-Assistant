import SwiftUI

/// A thin line with the day on it ("Today", "Yesterday", "Saturday 24 October").
struct DayDivider: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(K.glass).frame(height: 1)
            Text(label).font(KFont.meta).foregroundStyle(K.text3).fixedSize()
            Rectangle().fill(K.glass).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}
