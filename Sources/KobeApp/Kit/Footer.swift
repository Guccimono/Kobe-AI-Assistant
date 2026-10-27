import SwiftUI
import KobeKit

/// The keys that work in this view, always visible. Callers pass e.g. "Return opens", "Cmd F search".
struct Footer: View {
    let keys: [String]

    var body: some View {
        Text(keys.joined(separator: " · ")).font(KFont.meta).foregroundStyle(K.text3).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    Footer(keys: ["Return opens", "Cmd F search", "Esc closes"]).padding().background(.black)
}
