import Foundation

/// One of Kobe Agent's cron jobs, as `GET /api/jobs` lists it (the work page's "Scheduled").
public struct HermesJob: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// What Hermes shows for the schedule: its display text, else the cron expression.
    public let schedule: String
    public let nextRunAt: Date?
    public let paused: Bool

    public init(id: String, name: String, schedule: String, nextRunAt: Date?, paused: Bool) {
        self.id = id; self.name = name; self.schedule = schedule; self.nextRunAt = nextRunAt; self.paused = paused
    }

    /// "30 7 * * *" reads "every day 7:30" and "0 9 * * 1-5" "weekdays 9:00"; anything else stays as Hermes wrote it.
    public static func readable(_ schedule: String) -> String {
        let fields = schedule.split(separator: " ").map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]), (0..<60).contains(minute),
              (0..<24).contains(hour), fields[2] == "*", fields[3] == "*" else { return schedule }
        let time = "\(hour):" + (minute < 10 ? "0\(minute)" : "\(minute)")
        switch fields[4] {
        case "*": return "every day \(time)"
        case "1-5": return "weekdays \(time)"
        default: return schedule
        }
    }
}

/// Reads the jobs list. Kept tolerant on purpose: Hermes has changed this shape between releases, so a wrapped
/// (`data` or `jobs`) or bare list, a string or object schedule, ISO or epoch dates and three ways of saying
/// "paused" (`paused`, `enabled: false`, `state: "paused"`) all read. A job without an id is skipped.
public enum HermesJobs {
    public static func parse(_ data: Data, copy: Copy = Copy(name: "Kobe")) throws -> [HermesJob] {
        let root = try JSONSerialization.jsonObject(with: data)
        let list: [Any]
        if let array = root as? [Any] {
            list = array
        } else if let object = root as? [String: Any], let array = (object["data"] ?? object["jobs"]) as? [Any] {
            list = array
        } else {
            throw HermesError.server(status: 200, code: "bad_response", message: "Unexpected answer from \(copy.name)")
        }
        return list.compactMap { ($0 as? [String: Any]).flatMap(job) }
    }

    private static func job(_ fields: [String: Any]) -> HermesJob? {
        guard let id = string(fields["id"]) else { return nil }
        let name = string(fields["name"]) ?? id
        let paused = (fields["paused"] as? Bool) ?? ((fields["enabled"] as? Bool).map { !$0 } ?? (string(fields["state"]) == "paused"))
        return HermesJob(id: id, name: name, schedule: schedule(fields), nextRunAt: date(fields["next_run_at"]), paused: paused)
    }

    private static func schedule(_ fields: [String: Any]) -> String {
        if let display = string(fields["schedule_display"]) { return display }
        if let text = string(fields["schedule"]) { return text }
        if let object = fields["schedule"] as? [String: Any] {
            return string(object["display"]) ?? string(object["expr"]) ?? string(object["kind"]) ?? ""
        }
        return ""
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Epoch seconds (or milliseconds), or ISO 8601 with or without fractional seconds; no zone means local time
    /// (Python's naive `isoformat()`).
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is Bool) {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }
        for options in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            local.dateFormat = pattern
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}
