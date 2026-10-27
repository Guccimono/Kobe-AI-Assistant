import Foundation

// Your GitHub contribution calendar.

public struct ContributionDay: Equatable, Sendable {
    /// YYYY-MM-DD.
    public var date: String
    public var count: Int
    /// 0…4 (NONE, FIRST_QUARTILE … FOURTH_QUARTILE).
    public var level: Int
    /// 0 = Sunday … 6 = Saturday.
    public var weekday: Int

    public init(date: String, count: Int, level: Int, weekday: Int) {
        self.date = date
        self.count = count
        self.level = level
        self.weekday = weekday
    }
}

public struct GitHubActivity: Equatable, Sendable {
    public var total: Int
    /// Oldest first; the last week may be incomplete.
    public var weeks: [[ContributionDay]]
    public var fetchedAt: Date

    public init(total: Int, weeks: [[ContributionDay]], fetchedAt: Date) {
        self.total = total
        self.weeks = weeks
        self.fetchedAt = fetchedAt
    }

    public static func parse(_ data: Data) -> GitHubActivity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let viewer = dataNode["viewer"] as? [String: Any],
              let collection = viewer["contributionsCollection"] as? [String: Any],
              let calendar = collection["contributionCalendar"] as? [String: Any],
              let total = calendar["totalContributions"] as? Int,
              let weeksRaw = calendar["weeks"] as? [[String: Any]] else { return nil }
        var weeks: [[ContributionDay]] = []
        for week in weeksRaw {
            let days: [ContributionDay] = (week["contributionDays"] as? [[String: Any]] ?? []).compactMap { day in
                guard let date = day["date"] as? String, let count = day["contributionCount"] as? Int,
                      let level = day["contributionLevel"] as? String, let weekday = day["weekday"] as? Int else { return nil }
                return ContributionDay(date: date, count: count, level: Self.level(level), weekday: weekday)
            }
            if !days.isEmpty { weeks.append(days) }
        }
        return GitHubActivity(total: total, weeks: weeks, fetchedAt: Date())
    }

    private static func level(_ raw: String) -> Int {
        switch raw {
        case "FIRST_QUARTILE": 1
        case "SECOND_QUARTILE": 2
        case "THIRD_QUARTILE": 3
        case "FOURTH_QUARTILE": 4
        default: 0
        }
    }

    /// The last `n` weeks, oldest first.
    public func lastWeeks(_ n: Int) -> [[ContributionDay]] {
        guard n > 0 else { return [] }
        return Array(weeks.suffix(n))
    }

    /// The last `n` days, oldest first.
    public func lastDays(_ n: Int) -> [ContributionDay] {
        guard n > 0 else { return [] }
        return Array(weeks.joined().suffix(n))
    }

    /// How many week columns fit in `width` (23 fit in 202 pt), at most a year's 53.
    public static func weeksThatFit(width: Double, square: Double, spacing: Double) -> Int {
        guard width > 0, square > 0 else { return 0 }
        return min(53, max(0, Int((width + spacing) / (square + spacing))))
    }
}
