import SwiftUI
import KobeKit

/// The 36 pt bar at the top of every widget: tabs on the left, actions on the right. The caller ends `trailing`
/// with the close button, so the bar stays dumb and every page decides what it offers.
struct TabBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            leading
            Spacer(minLength: Spacing.sm)
            trailing
        }
        .frame(height: 36)
    }
}

/// One tab: text on a glass capsule when selected.
struct KitTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(KFont.row).foregroundStyle(selected ? K.text1 : K.text2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? K.glassActive : .clear, in: Capsule())
                .overlay(alignment: .top) {
                    if selected { Capsule().fill(K.glassHighlight).frame(height: 1).padding(.horizontal, 6) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    TabBar {
        KitTab(title: "Home", selected: true) {}
        KitTab(title: "Chat", selected: false) {}
    } trailing: {
        KitIconButton(icon: .x, help: "Close") {}
    }
    .padding().background(.black)
}
