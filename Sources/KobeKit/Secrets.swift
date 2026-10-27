import Foundation
import Security
import Synchronization

/// What a Keychain read came back with. Only `found` and `missing` are answers worth remembering: a `failed` read
/// (Keychain locked, access denied, interrupted) says nothing about the item and must be asked again later.
public enum SecretRead: Equatable, Sendable {
    case found(Data)
    case missing
    case failed(OSStatus)
}

/// The few Keychain operations Kobe needs, so the logic can be tested without touching the real Keychain.
public protocol SecretStoring: Sendable {
    /// Whether the item exists. Attributes only: never prompts.
    func exists(service: String, account: String) -> Bool
    /// Reads the secret, telling a missing item from a read that failed. May prompt, if the item's access list
    /// doesn't name this app.
    func fetch(service: String, account: String) -> SecretRead
    /// Adds a fresh item (after the first unlock, this device only). Fails if one exists: callers delete first.
    func write(service: String, account: String, data: Data) -> Bool
    func delete(service: String, account: String)
}

public extension SecretStoring {
    /// The secret's bytes; nil for a missing item and for a failed read alike (use `fetch` to tell them apart).
    func read(service: String, account: String) -> Data? {
        if case .found(let data) = fetch(service: service, account: account) { return data }
        return nil
    }
}

/// The login Keychain, generic passwords.
public struct KeychainSecrets: SecretStoring {
    public init() {}

    private func base(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func exists(service: String, account: String) -> Bool {
        var query = base(service, account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    public func fetch(service: String, account: String) -> SecretRead {
        var query = base(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: return (item as? Data).map(SecretRead.found) ?? .failed(errSecDecode)
        case errSecItemNotFound: return .missing
        case let status: return .failed(status)
        }
    }

    public func write(service: String, account: String, data: Data) -> Bool {
        var query = base(service, account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public func delete(service: String, account: String) {
        SecItemDelete(base(service, account) as CFDictionary)
    }
}

/// Secrets held in memory only, for tests and screenshots: never touches the real Keychain.
public final class InMemorySecrets: SecretStoring {
    private let items = Mutex<[String: Data]>([:])

    public init() {}

    private func key(_ service: String, _ account: String) -> String { service + "\u{0}" + account }
    public func exists(service: String, account: String) -> Bool { items.withLock { $0[key(service, account)] != nil } }
    public func fetch(service: String, account: String) -> SecretRead {
        items.withLock { $0[key(service, account)].map(SecretRead.found) ?? .missing }
    }
    public func write(service: String, account: String, data: Data) -> Bool {
        items.withLock {
            guard $0[key(service, account)] == nil else { return false }
            $0[key(service, account)] = data
            return true
        }
    }
    public func delete(service: String, account: String) { _ = items.withLock { $0.removeValue(forKey: key(service, account)) } }
}

/// The Hermes API key: one Keychain item (service `com.kobe-assistant.app.engine`, account = the Mac user name). Read from the
/// Keychain once, then kept in memory, so macOS never asks twice; a read that failed is asked again next time, never
/// remembered as "no key". Never logged or shown.
public final class HermesKey: Sendable {
    public static let service = Brand.engineKeychain

    public let store: any SecretStoring
    public let account: String
    /// nil = not read yet; .some(nil) = read, nothing there.
    private let cached = Mutex<String??>(nil)

    public init(store: any SecretStoring = KeychainSecrets(), account: String = NSUserName()) {
        self.store = store
        self.account = account
    }

    public func load() -> String? {
        cached.withLock { cache in
            if let known = cache { return known }
            switch store.fetch(service: Self.service, account: account) {
            case .found(let data):
                let value = String(data: data, encoding: .utf8)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                cache = .some(value)
                return value
            case .missing:
                cache = .some(nil)
                return nil
            case .failed:
                return nil
            }
        }
    }

    /// Trims whitespace; refuses an empty key and one with whitespace inside (two keys pasted, a stray line).
    /// Replaces any existing item.
    @discardableResult
    public func save(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !Self.hasInnerWhitespace(value) else { return false }
        store.delete(service: Self.service, account: account)
        guard store.write(service: Self.service, account: account, data: Data(value.utf8)) else { return false }
        cached.withLock { $0 = .some(value) }
        return true
    }

    /// Space, tab or line break anywhere in an already trimmed key.
    public static func hasInnerWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// Removes the item; the next `load` answers nil without asking the Keychain again.
    public func delete() {
        store.delete(service: Self.service, account: account)
        cached.withLock { $0 = .some(nil) }
    }

    public var isSet: Bool { load() != nil }
}
