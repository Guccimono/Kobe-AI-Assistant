import Foundation

/// One sRGB colour as a hex value; the app target turns it into a SwiftUI `Color`.
public struct RGB: Equatable, Sendable {
    public let hex: UInt32
    public init(_ hex: UInt32) { self.hex = hex }

    /// "#RRGGBB" or "RRGGBB" (the snapshots' calendar and list colours); nil for anything else.
    public init?(hex string: String) {
        let digits = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.hex = value
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }
}

/// A colour with an alpha, for the translucent "dark glass" layers.
public struct RGBA: Equatable, Sendable {
    public let rgb: RGB
    public let alpha: Double
    public init(_ hex: UInt32, _ alpha: Double) { self.rgb = RGB(hex); self.alpha = alpha }
}

/// Colour tokens from the spec's UI rules. Lime is a signal, never a fill; white is the primary button.
public enum Theme {
    public static let lime = RGB(0xC7F41E)
    public static let amber = RGB(0xF5A524)
    public static let red = RGB(0xF4505E)
    public static let green = RGB(0x34D399)

    /// Settings window floor, then panels one step lighter each.
    public static let window = RGB(0x0B0B0C)
    public static let panel = RGB(0x141417)
    public static let panel2 = RGB(0x1C1C20)
    public static let panel3 = RGB(0x26262B)
    public static let hairline = RGB(0x25252B)

    public static let text1 = RGB(0xF5F6F8)
    public static let text2 = RGB(0xA1A1AA)
    public static let text3 = RGB(0x71717A)

    /// "Dark glass" for controls on the black island: white at 6 %, 10 % when active, a 12 % top highlight.
    public static let glass = RGBA(0xFFFFFF, 0.06)
    public static let glassActive = RGBA(0xFFFFFF, 0.10)
    public static let glassHighlight = RGBA(0xFFFFFF, 0.12)
}

/// The seven type styles of the kit (SF Pro). Sizes and weights only; the app target turns them into fonts.
public enum Type {
    public enum Weight: Sendable { case regular, medium, semibold, bold }
    public struct Spec: Equatable, Sendable {
        public let size: Double
        public let weight: Weight
        public init(size: Double, weight: Weight) { self.size = size; self.weight = weight }
    }
    public static let title = Spec(size: 15, weight: .bold)
    public static let row = Spec(size: 13, weight: .semibold)
    public static let body = Spec(size: 13, weight: .regular)
    public static let secondary = Spec(size: 12, weight: .regular)
    public static let meta = Spec(size: 11, weight: .medium)
    public static let eyebrow = Spec(size: 10.5, weight: .semibold)
    public static let kpi = Spec(size: 20, weight: .bold)
}

public enum Radius {
    public static let row = 8.0
    public static let chip = 8.0
    /// The kit's text buttons (Primary, Glass, Danger): between a row (8) and a tab (12).
    public static let button = 10.0
    public static let capsule = 999.0
    public static let tab = 12.0
    public static let bubble = 16.0
    public static let panel = 24.0
    public static let islandSmall = 14.0
    public static let islandOpen = 22.0
}

/// 8 pt base.
public enum Spacing {
    public static let xs = 4.0
    public static let sm = 8.0
    public static let md = 12.0
    public static let base = 16.0
    public static let lg = 24.0
    public static let xl = 32.0
    public static let xxl = 48.0
}

/// The island curves: a spring with a slight overshoot to open, an ease-out to fold.
public enum Motion {
    public static let openResponse = 0.5
    public static let openDamping = 0.72
    public static let closeDuration = 0.34
    public static let closeCurve = (0.45, 0.0, 0.2, 1.0)
}
