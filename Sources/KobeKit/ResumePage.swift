import Foundation

/// Reopening where you left off: the page the notch folded on, kept for the chosen minutes after it folded. Home or
/// anything that isn't a page (quick ask, a Claude card) clears it.
public struct ResumePage: Equatable, Sendable {
    /// Settings' choices, in minutes; 0 is off (the notch always opens on Home).
    public static let choices = [0, 2, 5, 10, 15, 30]

    private var page: WidgetID?
    private var at: Date?

    public init() {}

    public mutating func folded(on page: WidgetID?, at date: Date) {
        self.page = page == .now ? nil : page
        self.at = date
    }

    /// The page to reopen on, or nil for Home.
    public func page(now: Date, minutes: Int) -> WidgetID? {
        guard minutes > 0, let page, let at, now.timeIntervalSince(at) <= TimeInterval(minutes * 60) else { return nil }
        return page
    }
}
