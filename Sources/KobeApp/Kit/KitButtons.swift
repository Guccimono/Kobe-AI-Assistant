import SwiftUI
import KobeKit

/// Shared look for the three kit buttons; they differ only in fill and text colour.
private struct KitButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let text: Color

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .contentShape(.rect)
    }
}

/// White fill, near-black text. One per view.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KitButtonBody(configuration: configuration, fill: K.text1, text: K.window)
    }
}

/// Dark glass: the secondary button.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KitButtonBody(configuration: configuration, fill: K.glass, text: K.text2)
            .limeHoverBorder(radius: Radius.button)
    }
}

/// Red tint: destructive.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KitButtonBody(configuration: configuration, fill: K.red.opacity(0.16), text: K.red)
    }
}

/// A 28 pt glass capsule with one Phosphor icon (refresh, close, more).
struct KitIconButton: View {
    let icon: PhosphorIcon
    var help: String
    /// A state colour for the icon (keep awake on is lime); nil follows hover.
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    init(icon: PhosphorIcon, help: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.icon = icon; self.help = help; self.tint = tint; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(icon: icon, size: 14).foregroundStyle(tint ?? (hovering ? K.text1 : K.text2))
                .frame(width: 28, height: 28)
                .background(hovering ? K.glassActive : K.glass, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

#Preview {
    HStack {
        Button("Allow") {}.buttonStyle(PrimaryButtonStyle())
        Button("Open WhatsApp") {}.buttonStyle(GlassButtonStyle())
        Button("Delete") {}.buttonStyle(DangerButtonStyle())
        KitIconButton(icon: .x, help: "Close") {}
    }
    .padding().background(.black)
}
