import Foundation

// Stripe, Vercel and GitHub: each service's own API, called from this Mac with a key you paste once in
// Settings › Connections. Keys live in their own Keychain service, never on disk or in logs. Each service's client
// is in its own file (StripeClient.swift, VercelClient.swift, GitHubClient.swift).

public enum Service: String, CaseIterable, Sendable {
    case stripe, vercel, github
}

public enum ServiceError: Error, Equatable, Sendable {
    case badKey
    case offline
    case failed(String)

    public var message: String {
        switch self {
        case .badKey: "The key was refused. Check it in Settings › Connections."
        case .offline: "Can't reach the service right now."
        case .failed(let message): message
        }
    }
}

/// Service keys: Keychain service `com.kobe-assistant.app.services`, one account per service. Read once, cached;
/// a failed read is asked again on the next `load`.
public final class ServiceKeys: @unchecked Sendable {
    public static let service = Brand.servicesKeychain

    private let store: any SecretStoring
    private let lock = NSLock()
    private var cache: [Service: String?] = [:]

    public init(store: any SecretStoring = KeychainSecrets()) {
        self.store = store
    }

    public func load(_ service: Service) -> String? {
        lock.withLock {
            if let known = cache[service] { return known }
            switch store.fetch(service: Self.service, account: service.rawValue) {
            case .found(let data):
                let value = String(data: data, encoding: .utf8)
                cache[service] = .some(value)
                return value
            case .missing:
                cache[service] = .some(nil)
                return nil
            case .failed:
                return nil
            }
        }
    }

    public func isSet(_ service: Service) -> Bool { load(service) != nil }

    /// Trims; refuses empty keys and, for Stripe, full secret keys: a read-only restricted key (rk_…) is enough.
    @discardableResult
    public func save(_ raw: String, for service: Service) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if service == .stripe, value.hasPrefix("sk_") { return false }
        store.delete(service: Self.service, account: service.rawValue)
        guard store.write(service: Self.service, account: service.rawValue, data: Data(value.utf8)) else { return false }
        lock.withLock { cache[service] = .some(value) }
        return true
    }

    public func remove(_ service: Service) {
        store.delete(service: Self.service, account: service.rawValue)
        lock.withLock { cache[service] = .some(nil) }
    }
}
