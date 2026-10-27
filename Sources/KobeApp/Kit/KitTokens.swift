import SwiftUI
import KobeKit

extension RGBA {
    var color: Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: alpha) }
}

extension K {
    /// Dark glass: controls on the black island. The tokens live in Theme so they are tested.
    static let glass = Theme.glass.color
    static let glassActive = Theme.glassActive.color
    static let glassHighlight = Theme.glassHighlight.color
}

/// The kit's seven type styles (specs in `Type`), as SwiftUI fonts.
enum KFont {
    static let title = font(Type.title)
    static let row = font(Type.row)
    static let body = font(Type.body)
    static let secondary = font(Type.secondary)
    static let meta = font(Type.meta)
    static let eyebrow = font(Type.eyebrow)
    /// Tabular digits so numbers do not jitter when they change.
    static let kpi = font(Type.kpi).monospacedDigit()

    static func font(_ spec: Type.Spec) -> Font {
        let weight: Font.Weight = switch spec.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        return .system(size: spec.size, weight: weight)
    }
}
