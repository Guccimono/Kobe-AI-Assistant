import Foundation

/// The connections strip in the tab bar: which capsule sits where, its key, its colour, its icon and the label it
/// shows when raised. Pure so the geometry and the ⌘-keys are tested; the app's `Strip` only draws it.
public enum StripLayout {
    /// K first (Home), then the keys' order (approved 2026-10-24): messages, the Mac apps, then the business pages.
    /// Work and Memory are reached from Home, not the strip.
    public static let order: [WidgetID] = [.now, .whatsapp, .mail, .agenda, .reminders, .notes, .google, .stripe, .github, .vercel]
    /// Capsules overlap: an 18 pt step for 28 pt capsules leaves 10 pt of each one covered by the next.
    public static let step: CGFloat = 18, size: CGFloat = 28, raisedScale: CGFloat = 1.25
    /// How far the raised capsule's neighbours move away so the scaled capsule does not cover them.
    public static let slide: CGFloat = 10

    /// Leading x of capsule `index`. With one raised, those before it slide left and those after it slide right.
    public static func x(index: Int, raised: Int?) -> CGFloat {
        let base = CGFloat(index) * step
        guard let raised else { return base }
        if index < raised { return base - slide }
        if index > raised { return base + slide }
        return base
    }

    /// Width of the whole strip, with room for the slide on both ends so nothing is clipped.
    public static var width: CGFloat { CGFloat(order.count - 1) * step + size + 2 * slide }

    /// ⌘0 is Home (like Esc), ⌘1…⌘9 the connections in strip order; nil for pages that are not on the strip.
    public static func key(for id: WidgetID) -> Int? {
        order.firstIndex(of: id)
    }

    /// The page a digit opens; anything outside 0…9 is nothing.
    public static func id(forKey n: Int) -> WidgetID? {
        order.indices.contains(n) ? order[n] : nil
    }

    /// The digit on a physical key (top row or keypad), from its virtual key code (Carbon's kVK_ANSI_0…9 and
    /// kVK_ANSI_Keypad0…9). Read from the key, not the characters, so ⌘1 works on AZERTY, where that key types "&".
    public static func digit(forKeyCode code: UInt16) -> Int? {
        switch code {
        case 29: 0
        case 18: 1
        case 19: 2
        case 20: 3
        case 21: 4
        case 23: 5
        case 22: 6
        case 26: 7
        case 28: 8
        case 25: 9
        case 82...89: Int(code) - 82   // keypad 0…7
        case 91: 8
        case 92: 9
        default: nil
        }
    }

    public static func name(_ id: WidgetID) -> String {
        switch id {
        case .now: "Home"
        case .whatsapp: "WhatsApp"
        case .mail: "Mail"
        case .agenda: "Agenda"
        case .reminders: "Reminders"
        case .notes: "Notes"
        case .google: "Google"
        case .stripe: "Stripe"
        case .github: "GitHub"
        case .vercel: "Vercel"
        case .work: "Work"
        case .memory: "Memory"
        }
    }

    /// The chip words, shared with the page headers.
    public static func statusText(_ status: SnapshotStatus) -> String {
        switch status {
        case .ok: "All good"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .notSetUp: "Not set up"
        }
    }

    /// "Google · All good · ⌘6", or with a headline in place of the status words, "Mail · 3 unread · ⌘2". No
    /// snapshot yet: the status is left out rather than guessed.
    public static func label(_ id: WidgetID, status: SnapshotStatus?, headline: String? = nil) -> String {
        var parts = [name(id)]
        if let headline { parts.append(headline) } else if let status { parts.append(statusText(status)) }
        if let key = key(for: id) { parts.append("⌘\(key)") }
        return parts.joined(separator: " · ")
    }

    /// The spec's service tints; K is Kobe's lime (the one place lime is a fill).
    public static func tint(_ id: WidgetID) -> RGB {
        switch id {
        case .now: Theme.lime
        case .whatsapp: RGB(0x25D366)
        case .mail: RGB(0x1E90FF)
        case .agenda: RGB(0xF4505E)
        case .reminders: RGB(0xF5A524)
        case .google: RGB(0x4285F4)
        case .stripe: RGB(0x635BFF)
        case .github: RGB(0xE5E7EB)
        case .vercel: RGB(0xF5F5F5)
        case .notes: RGB(0xFFD60A)
        case .work, .memory: Theme.text2
        }
    }

    public static func icon(_ id: WidgetID) -> PhosphorIcon {
        switch id {
        case .now: .sparkleFill
        case .whatsapp: .whatsappLogoFill
        case .mail: .envelopeSimpleFill
        case .agenda: .calendarBlankFill
        case .reminders: .checkSquareFill
        case .google: .googleLogoFill
        case .stripe: .stripeLogoFill
        case .github: .githubLogoFill
        case .vercel: .triangleFill
        case .notes: .noteFill
        case .work: .terminalWindowFill
        case .memory: .stack
        }
    }
}
