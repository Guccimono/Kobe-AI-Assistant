import SwiftUI
import KobeKit

/// A list row: radius 8, white 6 % on hover, the service tint at 8 % when unread, a white 12 % ring when the
/// page's keyboard selection is on it (`focused`). The page runs Return for the selected row (`PageScaffold`);
/// the row's own Return only answers real SwiftUI focus. `stacked` puts the subtitle under the title (Home's
/// comfortable Now rows). `detail` replaces the subtitle with styled text (WhatsApp's "You:" and @mentions).
struct KitRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var detail: Text?
    var meta: String?
    var tint: Color?
    var focused = false
    var stacked = false
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var hasFocus: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading
                if stacked {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(KFont.row).foregroundStyle(K.text1).lineLimit(1)
                        if let detail { detail.font(KFont.secondary).foregroundStyle(K.text2).lineLimit(1) }
                        else if let subtitle { Text(subtitle).font(KFont.secondary).foregroundStyle(K.text2).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    if let meta { Text(meta).font(KFont.meta).foregroundStyle(K.text3) }
                } else {
                    Text(title).font(KFont.row).foregroundStyle(K.text1).lineLimit(1)
                    if let meta { Text(meta).font(KFont.meta).foregroundStyle(K.text3) }
                    if let detail { detail.font(KFont.body).foregroundStyle(K.text2).lineLimit(1) }
                    else if let subtitle { Text(subtitle).font(KFont.body).foregroundStyle(K.text2).lineLimit(1) }
                    Spacer(minLength: 0)
                }
                trailing
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(K.glassHighlight, lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused($hasFocus)
        .onKeyPress(.return) { guard hasFocus else { return .ignored }; action(); return .handled }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        if hovering || focused || hasFocus { return K.glass }
        return tint?.opacity(0.08) ?? .clear
    }
}

#Preview {
    VStack {
        KitRow(title: "Lea", subtitle: "Dinner tonight?", meta: "now", tint: K.green, leading: { Dot(color: K.green) },
               trailing: { StatusChip(text: "2", tone: .ok) }, action: {})
        KitRow(title: "Marc", subtitle: "Thanks", leading: { EmptyView() }, trailing: { EmptyView() }, action: {})
    }
    .padding().background(.black)
}
