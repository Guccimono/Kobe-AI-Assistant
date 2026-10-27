import Foundation

/// The connection pages the agent writes a snapshot for. Raw values are the file names in `widgets/`.
public enum WidgetID: String, CaseIterable, Codable, Sendable {
    case now, whatsapp, mail, agenda, reminders, notes, google, stripe, github, vercel, work, memory
}

/// Drives the strip badge, the pill line and the header chip.
public enum SnapshotStatus: String, Codable, Sendable {
    case ok
    case needsYou = "needs_you"
    case failed
    case notSetUp = "not_set_up"
}

/// Who wrote a snapshot: Kobe Agent, or the app's shim while it still runs that connector. Absent means the app.
public enum SnapshotSource: String, Codable, Sendable {
    case app, agent
}

/// The envelope every snapshot file shares; `data` is page-specific.
public struct WidgetSnapshot<Data: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let id: WidgetID
    public let version: Int
    public let updatedAt: Date
    public let status: SnapshotStatus
    public let headline: String
    public let detail: String
    public let error: String?
    public let data: Data
    public let source: SnapshotSource

    public init(id: WidgetID, version: Int = SnapshotRules.version, updatedAt: Date, status: SnapshotStatus,
                headline: String, detail: String, error: String? = nil, data: Data, source: SnapshotSource = .app) {
        self.id = id; self.version = version; self.updatedAt = updatedAt; self.status = status
        self.headline = headline; self.detail = detail; self.error = error; self.data = data; self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, updatedAt, status, headline, detail, error, data, source
    }

    /// Tolerant of the other writer: a status this app doesn't know reads as failed (saying which), and a file
    /// without `source` was written by the app.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(WidgetID.self, forKey: .id)
        version = try c.decode(Int.self, forKey: .version)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        headline = try c.decode(String.self, forKey: .headline)
        detail = try c.decode(String.self, forKey: .detail)
        data = try c.decode(Data.self, forKey: .data)
        source = (try? c.decodeIfPresent(SnapshotSource.self, forKey: .source)) ?? .app
        let raw = try c.decode(String.self, forKey: .status)
        if let known = SnapshotStatus(rawValue: raw) {
            status = known
            error = try c.decodeIfPresent(String.self, forKey: .error)
        } else {
            status = .failed
            error = "Unknown status \(raw)"
        }
    }
}

public enum Freshness: Equatable, Sendable {
    case fresh(age: TimeInterval)
    case stale(age: TimeInterval)
    case unknown
}

public enum SnapshotRules {
    /// Bump when the envelope changes incompatibly; older apps then ignore newer files instead of misreading them.
    public static let version = 1

    /// Stale when age > 3 × schedule; unknown when `updatedAt` is missing or in the future by more than 60 s
    /// (small clock skew between the two macOS users is tolerated).
    public static func freshness(updatedAt: Date?, schedule: TimeInterval, now: Date = .now) -> Freshness {
        guard let updatedAt else { return .unknown }
        let age = now.timeIntervalSince(updatedAt)
        if age < -60 { return .unknown }
        let clamped = max(age, 0)
        return clamped > 3 * schedule ? .stale(age: clamped) : .fresh(age: clamped)
    }

    /// The meta line under a page title: "updated 2 min ago · Kobe", "stale · 25 min · Kobe", "never updated".
    public static func metaText(_ f: Freshness, source: String = "Kobe") -> String {
        switch f {
        case .unknown: return "never updated"
        case .fresh(let age): return "updated \(ago(age)) · \(source)"
        case .stale(let age): return "stale · \(span(age)) · \(source)"
        }
    }

    /// Default refresh interval per connection, in seconds (spec §3.6). `memory` refreshes on change, so a day.
    public static func schedule(for id: WidgetID) -> TimeInterval {
        switch id {
        case .now, .mail, .vercel: 300
        case .whatsapp: 120
        case .stripe, .github: 600
        case .notes: 900
        // Agenda and Reminders rewrite on change and at time boundaries; the hour is their heartbeat.
        case .google, .agenda, .reminders: 3600
        case .work: 60
        case .memory: 86_400
        }
    }

    /// "just now", "4 min ago": the age part of the meta line, also used by Home's eyebrow and memory line.
    public static func ago(_ age: TimeInterval) -> String {
        age < 60 ? "just now" : "\(span(age)) ago"
    }

    private static func span(_ age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        if minutes < 1 { return "\(Int(age)) s" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h" }
        return "\(hours / 24) d"
    }
}

public enum SnapshotDecode {
    private struct Header: Decodable { let version: Int }
    private struct Owner: Decodable { let updatedAt: Date; let source: SnapshotSource? }

    /// Who wrote a file and when, without decoding its data (the shim asks before each write). nil for a partial file.
    public static func header(_ data: Foundation.Data) -> (source: SnapshotSource, updatedAt: Date)? {
        guard let owner = try? decoder().decode(Owner.self, from: data) else { return nil }
        return (owner.source ?? .app, owner.updatedAt)
    }

    /// nil for empty or partial JSON (a write in progress), a mismatched data shape, or a newer version.
    public static func decode<D: Codable & Sendable & Equatable>(_ data: Foundation.Data, as: D.Type) -> WidgetSnapshot<D>? {
        let decoder = decoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.version <= SnapshotRules.version,
              let snapshot = try? decoder.decode(WidgetSnapshot<D>.self, from: data) else { return nil }
        return snapshot
    }

    /// snake_case keys; ISO 8601 dates with or without fractional seconds (Kobe Agent writes whole seconds, but a
    /// hand-made or future file may not).
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        return decoder
    }
}

public enum SnapshotEncode {
    /// The wire format `SnapshotDecode` reads: snake_case keys, ISO 8601 dates without fractional seconds.
    public static func encode<D: Codable & Sendable & Equatable>(_ snapshot: WidgetSnapshot<D>) throws -> Foundation.Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }
}
