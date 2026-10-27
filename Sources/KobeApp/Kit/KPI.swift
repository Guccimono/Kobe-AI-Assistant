import SwiftUI
import KobeKit

/// A label over a big tabular number, with an optional delta. `deltaUp` colours it (nil = neutral).
struct KPI: View {
    let label: String
    let value: String
    var delta: String?
    var deltaUp: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(KFont.eyebrow).tracking(0.63).foregroundStyle(K.text3)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(KFont.kpi).tracking(-0.4).foregroundStyle(K.text1)
                if let delta { Text(delta).font(KFont.meta).foregroundStyle(deltaColor) }
            }
        }
    }

    private var deltaColor: Color {
        guard let deltaUp else { return K.text3 }
        return deltaUp ? K.green : K.red
    }
}

#Preview {
    HStack(spacing: 24) {
        KPI(label: "Orders", value: "1,284", delta: "+12%", deltaUp: true)
        KPI(label: "Refunds", value: "9", delta: "+3", deltaUp: false)
        KPI(label: "Visits", value: "4,010")
    }
    .padding().background(.black)
}
