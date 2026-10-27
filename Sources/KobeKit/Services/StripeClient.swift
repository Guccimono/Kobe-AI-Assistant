import Foundation

// Stripe: the balance and the last three charges, read-only. Nothing here can
// move money: only two GETs against api.stripe.com, with the key as Basic auth username and an empty password.

/// One charge.
public struct StripePayment: Identifiable, Equatable, Sendable {
    public let id: String
    /// In the smallest unit (cents).
    public let amount: Int
    public let currency: String
    /// The charge's description, else the billing name.
    public let description: String?
    public let createdAt: Date
    /// "succeeded", "pending", "failed".
    public let status: String

    public init(id: String, amount: Int, currency: String, description: String?, createdAt: Date, status: String) {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.description = description
        self.createdAt = createdAt
        self.status = status
    }

    public var isSuccess: Bool { status == "succeeded" }
    public var amountFormatted: String { String(format: "%.2f", Double(amount) / 100) }

    /// "just now", "Nm", "Nh", "Nd".
    public func timeAgo(now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(createdAt)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        return "\(Int(diff / 86400))d"
    }
}

/// Available + pending, so a charge that just landed counts at once.
public struct StripeBalance: Equatable, Sendable {
    public let amount: Int
    public let currency: String

    public init(amount: Int, currency: String) {
        self.amount = amount
        self.currency = currency
    }

    public var formatted: String { String(format: "%.2f", Double(amount) / 100) }
}

/// A balance request that failed, with the message the card and Settings show.
public struct StripeFailure: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

public struct StripeClient: Sendable {
    public static let api = URL(string: "https://api.stripe.com")!

    private let key: String
    private let base: URL
    let session: URLSession

    public init(key: String, base: URL = StripeClient.api, session: URLSession = .kobeEphemeral) {
        self.key = key
        self.base = base
        self.session = session
    }

    /// GET /v1/balance.
    public func balance() async throws(StripeFailure) -> StripeBalance {
        let (data, status, error) = await get("v1/balance")
        guard status == 200, let data else { throw StripeFailure(message: Self.message(status: status, error: error)) }
        guard let balance = Self.parseBalance(data) else { throw StripeFailure(message: "API error \(status)") }
        return balance
    }

    /// GET /v1/charges?limit=3, newest first. Its errors give nil. `since` keeps the charges created
    /// from then on (`created[gte]`), for a page period's totals.
    public func charges(limit: Int = 3, since: Date? = nil) async -> [StripePayment]? {
        var query = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let since { query.append(URLQueryItem(name: "created[gte]", value: "\(Int(since.timeIntervalSince1970))")) }
        let (data, status, _) = await get("v1/charges", query: query)
        guard status == 200, let data else { return nil }
        return Self.parseCharges(data)
    }

    /// GET /v1/payouts?limit=1: when the next payout lands. Errors (a key without Payouts read access) are nil,
    /// like the charges: the page just leaves the date out.
    public func nextPayout() async -> Date? {
        let (data, status, _) = await get("v1/payouts", query: [URLQueryItem(name: "limit", value: "1")])
        guard status == 200, let data else { return nil }
        return Self.parseNextPayout(data)
    }

    /// The newest payout's arrival date while it is still on its way (pending or in transit); a paid one is the
    /// last payout, not the next.
    public static func parseNextPayout(_ data: Data) -> Date? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newest = (json["data"] as? [[String: Any]])?.first,
              let status = newest["status"] as? String, status == "pending" || status == "in_transit",
              let arrival = newest["arrival_date"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: arrival)
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async -> (Data?, Int, Error?) {
        var url = base.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Basic " + Data("\(key):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0, nil)
        } catch {
            return (nil, 0, error)
        }
    }

    /// The balance error messages. Kobe only accepts restricted keys, so a 403 means missing permissions.
    public static func message(status: Int, error: Error?) -> String {
        switch status {
        case 401: "Invalid API key (401)"
        case 403: "This key can't read the balance: give the restricted key read access to Balance and Charges."
        case 0: error?.localizedDescription ?? "No connection"
        default: "API error \(status)"
        }
    }

    /// Sum of every available and pending bucket; the currency is the first bucket's, "eur" when there is none.
    public static func parseBalance(_ data: Data) -> StripeBalance? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let buckets = (json["available"] as? [[String: Any]] ?? []) + (json["pending"] as? [[String: Any]] ?? [])
        let currency = buckets.first?["currency"] as? String ?? "eur"
        let amount = buckets.compactMap { $0["amount"] as? Int }.reduce(0, +)
        return StripeBalance(amount: amount, currency: currency)
    }

    public static func parseCharges(_ data: Data) -> [StripePayment]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { charge in
            guard let id = charge["id"] as? String,
                  let amount = charge["amount"] as? Int,
                  let currency = charge["currency"] as? String,
                  let status = charge["status"] as? String else { return nil }
            let created = charge["created"] as? TimeInterval ?? 0
            let description = charge["description"] as? String
                ?? (charge["billing_details"] as? [String: Any]).flatMap { $0["name"] as? String }
            return StripePayment(id: id, amount: amount, currency: currency, description: description,
                                 createdAt: Date(timeIntervalSince1970: created), status: status)
        }
    }

    /// A new charge: finished + "finish" when it succeeded, error + "error" otherwise.
    public static func event(for payment: StripePayment) -> ServiceEvent {
        let amount = "+\(payment.amountFormatted) \(payment.currency.uppercased())"
        let detail = payment.description.map { "\(amount) · \($0)" } ?? amount
        return payment.isSuccess
            ? ServiceEvent(pill: "stripe", kind: .finished, detail: detail, sound: .finish)
            : ServiceEvent(pill: "stripe", kind: .error, detail: detail, sound: .error)
    }
}

/// The new-charge rule: the first load only records the newest charge; afterwards a different newest charge
/// is reported once.
public struct StripeChargeWatcher: Sendable {
    private var primed = false
    private var lastId: String?

    public init() {}

    /// The charge to report, or nil.
    public mutating func observe(_ payments: [StripePayment]) -> StripePayment? {
        let newest = payments.first
        defer { if newest != nil || !primed { lastId = newest?.id }; primed = true }
        guard primed, let newest, newest.id != lastId else { return nil }
        return newest
    }

    /// The key changed: the next load is a first load again.
    public mutating func reset() {
        primed = false
        lastId = nil
    }
}
