import Foundation

/// Hiding amounts bank-style ("€•••"): the Stripe page's eye and ⌘H, kept in Settings. Kobe Agent still sees the
/// numbers; only what the notch draws changes.
public enum MoneyMask {
    public static let dots = "•••"

    /// "€•••", "MX$•••", "CHF •••".
    public static func hidden(_ currency: String) -> String {
        SnapshotBuilders.symbol(currency) + dots
    }

    /// `SnapshotBuilders.money`, or the hidden form.
    public static func money(_ minor: Int, _ currency: String, hidden: Bool) -> String {
        hidden ? Self.hidden(currency) : SnapshotBuilders.money(minor, currency)
    }

    /// Replaces every amount in a line of text (a Now row, a headline) with its symbol and the dots. A symbol
    /// (€ $ £ MX$) or a three-letter code and a space, then digits with separators; other numbers stay.
    public static func mask(_ text: String) -> String {
        let amount = /(MX\$|€|\$|£|\b[A-Z]{3} )[0-9][0-9,.]*/
        return text.replacing(amount) { match in String(match.output.1) + dots }
    }
}
