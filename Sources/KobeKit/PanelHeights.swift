import Foundation

/// The resize handle's rules: the open island grows from its default height up to about 90% of the screen.
public enum PanelHeights {
    /// Open island: 780 wide and 360 tall below the band by default.
    public static let notchDefault: Double = 360
    public static let notchWidthDefault: Double = 780
    public static let notchWidthRange: ClosedRange<Double> = 640...1100
    public static let screenFraction = 0.9

    /// The height to use: a remembered one, clamped, or the default when nothing (0) is remembered.
    public static func resolve(remembered: Double, defaultHeight: Double, screenHeight: Double) -> Double {
        let upper = max(defaultHeight, (screenHeight * screenFraction).rounded(.down))
        guard remembered > 0 else { return min(defaultHeight, upper) }
        return min(max(remembered, defaultHeight), upper)
    }
}
