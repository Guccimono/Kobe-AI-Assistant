import Foundation

/// The Google page's numbers: KPI values and their week-on-week deltas. A delta's `good` colours it (green, red,
/// nil neutral); for search position lower is better, so a fall is good.
public enum GoogleFormat {
    public struct Delta: Equatable, Sendable {
        public let text: String
        public let good: Bool?
        public init(text: String, good: Bool?) { self.text = text; self.good = good }
    }

    /// "+13 %", "−36 %", "0 %"; nil without a previous period to compare with.
    public static func deltaPercent(_ now: Int, _ prev: Int) -> Delta? {
        guard prev > 0 else { return nil }
        let pct = Int((Double(now - prev) * 100 / Double(prev)).rounded())
        return Delta(text: pct > 0 ? "+\(pct) %" : pct < 0 ? "−\(-pct) %" : "0 %", good: pct == 0 ? nil : pct > 0)
    }

    /// "−0.7" (better), "+1.2" (worse), "0.0"; nil when either period has no position.
    public static func positionDelta(_ now: Double, _ prev: Double) -> Delta? {
        guard now > 0, prev > 0 else { return nil }
        let diff = ((now - prev) * 10).rounded() / 10
        let text = String(format: "%.1f", abs(diff))
        return Delta(text: diff > 0 ? "+\(text)" : diff < 0 ? "−\(text)" : text, good: diff == 0 ? nil : diff < 0)
    }

    /// 1240 → "1,240".
    public static func count(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "8.4", "—" when Search Console had no position.
    public static func position(_ p: Double) -> String { p > 0 ? String(format: "%.1f", p) : "—" }

    /// Business Profile calls, "—" until that API is granted.
    public static func calls(_ n: Int?) -> String { n.map(count) ?? "—" }

    /// The site a Search Console report URL is about: "sc-domain:example.org" → "example.org", "https://www.example.org/" →
    /// "www.example.org". For the header's meta line.
    public static func site(searchURL: String) -> String? {
        guard let items = URLComponents(string: searchURL)?.queryItems,
              let resource = items.first(where: { $0.name == "resource_id" })?.value, !resource.isEmpty else { return nil }
        if resource.hasPrefix("sc-domain:") { return String(resource.dropFirst("sc-domain:".count)) }
        return URL(string: resource)?.host() ?? resource
    }
}
