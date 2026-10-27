import Foundation

/// The keys pasted on the "Pick a brain" screen, in the same Keychain item as the other service keys
/// (`Brand.servicesKeychain`), one account per door. Ollama has no key.
public final class BrainKeys: @unchecked Sendable {
    private let store: any SecretStoring

    public init(store: any SecretStoring = KeychainSecrets()) { self.store = store }

    static func account(_ brain: Brain) -> String? {
        brain.needsKey ? "brain-" + brain.rawValue : nil
    }

    public func load(_ brain: Brain) -> String? {
        guard let account = Self.account(brain),
              let data = store.read(service: Brand.servicesKeychain, account: account) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Trims; refuses an empty key, one with whitespace inside and a brain without keys.
    @discardableResult
    public func save(_ raw: String, for brain: Brain) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = Self.account(brain), !value.isEmpty, !HermesKey.hasInnerWhitespace(value) else { return false }
        store.delete(service: Brand.servicesKeychain, account: account)
        return store.write(service: Brand.servicesKeychain, account: account, data: Data(value.utf8))
    }

    public func delete(for brain: Brain) {
        guard let account = Self.account(brain) else { return }
        store.delete(service: Brand.servicesKeychain, account: account)
    }
}
