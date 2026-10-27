import AppKit
import SwiftUI
import KobeKit

extension RGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

enum K {
    static let lime = Theme.lime.color
    static let amber = Theme.amber.color
    static let red = Theme.red.color
    static let green = Theme.green.color
    static let window = Theme.window.color
    static let panel = Theme.panel.color
    static let panel2 = Theme.panel2.color
    static let panel3 = Theme.panel3.color
    static let hairline = Theme.hairline.color
    static let text1 = Theme.text1.color
    static let text2 = Theme.text2.color
    static let text3 = Theme.text3.color
}

/// A Phosphor icon as a template image, tinted by the foreground style.
struct Icon: View {
    let icon: PhosphorIcon
    var size: CGFloat = 20

    @MainActor private static var cache: [PhosphorIcon: NSImage] = [:]

    var body: some View {
        if let image = Self.image(icon) {
            Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    @MainActor static func image(_ icon: PhosphorIcon) -> NSImage? {
        if let known = cache[icon] { return known }
        guard let url = icon.url(), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[icon] = image
        return image
    }
}

/// Small uppercase lime label above a heading.
struct Eyebrow: View {
    let text: String
    var color: Color = K.lime
    init(_ text: String, color: Color = K.lime) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(color)
    }
}

/// The hover rule: a 1 pt lime border (Kobe's accent) on hover or keyboard focus, nothing otherwise. No lift, no shadow.
struct LimeHoverBorder: ViewModifier {
    var radius: CGFloat
    @State private var hovering = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(K.lime.opacity(hovering || focused ? 0.7 : 0), lineWidth: 1))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func limeHoverBorder(radius: CGFloat = 16) -> some View { modifier(LimeHoverBorder(radius: radius)) }

    /// A panel on the island or a card in Settings.
    func panelSurface(_ fill: Color = K.panel, radius: CGFloat = Radius.panel) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A small copy icon that appears when the pointer is over a message; click copies the text.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            Icon(icon: copied ? .check : .copySimple, size: 12)
                .foregroundStyle(copied ? K.lime : K.text3)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy")
    }
}

/// Shows the copy button beside a message while the pointer is over it.
struct Copyable: ViewModifier {
    let text: String
    let trailing: Bool
    var caption: String?
    @State private var hovering = false

    func body(content: Content) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            if !trailing, let caption { captionView(caption) }
            if trailing { content }
            CopyButton(text: text).opacity(hovering ? 1 : 0)
            if !trailing { content }
            if trailing, let caption { captionView(caption) }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The time of the message, beside the copy icon, only while the pointer is over the message.
    private func captionView(_ text: String) -> some View {
        Text(text).font(KFont.meta).foregroundStyle(K.text3).padding(.bottom, 8).opacity(hovering ? 1 : 0)
    }
}

extension View {
    /// A copy icon on hover; `trailing` puts it after the content (for messages on the left). `caption` (the time)
    /// shows beside the icon on the same hover.
    func copyable(_ text: String, trailing: Bool, caption: String? = nil) -> some View {
        modifier(Copyable(text: text, trailing: trailing, caption: caption))
    }
}

/// A small coloured status dot.
struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

enum Animations {
    /// Content fades in once the shape has (nearly) finished growing, so text never shows over a half-spread island;
    /// it fades out at once when folding.
    static func contentIn(after delay: Double) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(reduceMotion ? 0 : delay)),
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var open: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: Motion.openResponse, dampingFraction: Motion.openDamping)
    }
    static var close: Animation {
        reduceMotion ? .easeInOut(duration: 0.2)
            : .timingCurve(Motion.closeCurve.0, Motion.closeCurve.1, Motion.closeCurve.2, Motion.closeCurve.3, duration: Motion.closeDuration)
    }
}
