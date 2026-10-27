import Foundation

/// WhatsApp's choices (Settings › Connections › WhatsApp). Secrets (gateway URL, credential, webhook
/// secret) live in the Keychain, service `com.kobe-assistant.app.services`; only harmless choices go to
/// UserDefaults. Keychain items are read once, then kept in memory, so macOS never asks twice; a read that failed is
/// asked again next time.
///
/// Kept from the first Kobe link: GOWA in `~/Library/Application Support/Kobe/GOWA`, on port 47840, with the
/// basic auth stored as `gowa-auth` (used, and copied to `whatsapp-api-key`, when that one is missing).
public final class WhatsAppSettings: @unchecked Sendable {
    public static let service = ServiceKeys.service
    public static let urlKey = "whatsapp-url"
    public static let credentialKey = "whatsapp-api-key"
    public static let secretKey = "whatsapp-webhook-secret"
    /// The first Kobe link's GOWA password ("kobe:<hex>").
    public static let legacyAuthKey = "gowa-auth"
    /// Kobe's webhook port (GOWA itself is on 47840).
    public static let defaultPort = 47841

    /// Where GOWA and its WhatsApp session live: `~/Library/Application Support/Kobe/GOWA`.
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(Brand.dataFolderName)/GOWA", isDirectory: true)
    }

    private let defaults: UserDefaults
    private let secrets: any SecretStoring
    public let folder: URL
    private let isExecutable: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    public init(defaults: UserDefaults = .standard, secrets: any SecretStoring = KeychainSecrets(),
                folder: URL = WhatsAppSettings.defaultFolder,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.defaults = defaults
        self.secrets = secrets
        self.folder = folder
        self.isExecutable = isExecutable
    }

    // MARK: UserDefaults

    /// "Show my WhatsApp messages". Unset: on when the first Kobe link was on.
    public var enabled: Bool {
        get { defaults.object(forKey: "whatsappEnabled") as? Bool ?? defaults.bool(forKey: "whatsappLinkOn") }
        set { defaults.set(newValue, forKey: "whatsappEnabled") }
    }

    public var gateway: WAGatewayKind {
        get { WAGatewayKind(rawValue: defaults.string(forKey: "whatsappGateway") ?? "") ?? .gowa }
        set { defaults.set(newValue.rawValue, forKey: "whatsappGateway") }
    }

    public var port: Int {
        get { let p = defaults.integer(forKey: "whatsappPort"); return (1024...65535).contains(p) ? p : Self.defaultPort }
        set { defaults.set(newValue, forKey: "whatsappPort") }
    }

    /// Read receipts: sent when a conversation is opened (on), or only when replying (off). Never on mere reception.
    public var markReadOnOpen: Bool {
        get { defaults.object(forKey: "whatsappMarkReadOnOpen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "whatsappMarkReadOnOpen") }
    }

    public var respectFocus: Bool {
        get { defaults.object(forKey: "whatsappRespectFocus") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "whatsappRespectFocus") }
    }

    public var filters: WAFilters {
        get {
            WAFilters(muteGroups: defaults.object(forKey: "whatsappMuteGroups") as? Bool ?? true,
                      ignored: Set(defaults.stringArray(forKey: "whatsappIgnored") ?? []))
        }
        set {
            defaults.set(newValue.muteGroups, forKey: "whatsappMuteGroups")
            defaults.set(Array(newValue.ignored).sorted(), forKey: "whatsappIgnored")
        }
    }

    /// "Start GOWA automatically". Unset: on when GOWA is already installed in Kobe's folder.
    public var autoStart: Bool {
        get { defaults.object(forKey: "whatsappAutoStartGOWA") as? Bool ?? isExecutable(defaultBinary.path) }
        set { defaults.set(newValue, forKey: "whatsappAutoStartGOWA") }
    }

    /// The GOWA binary Kobe starts (not a secret: UserDefaults). Unset or empty: the one in Kobe's folder.
    public var binaryPath: String {
        get {
            let stored = defaults.string(forKey: "whatsappGOWAPath")?.trimmingCharacters(in: .whitespaces) ?? ""
            return stored.isEmpty ? defaultBinary.path : stored
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "whatsappGOWAPath") }
    }

    /// GOWA's version once installed by Kobe.
    public var installedVersion: String? {
        get { defaults.string(forKey: "whatsappGOWAVersion") }
        set { defaults.set(newValue, forKey: "whatsappGOWAVersion") }
    }

    public var defaultBinary: URL { folder.appendingPathComponent("gowa") }

    /// A gateway Kobe can start: the one it installed, or one the user picked.
    public var isInstalled: Bool {
        let path = (binaryPath as NSString).expandingTildeInPath
        return !path.isEmpty && isExecutable(path)
    }

    // MARK: Keychain

    public func secret(_ account: String) -> String? {
        if case .value(let value) = lookup(account) { return value }
        return nil
    }

    private enum Lookup { case value(String?), failed }

    /// The cached secret, or the Keychain's answer: `.value(nil)` for no item (remembered), `.failed` for a read
    /// that didn't succeed (not remembered, so it is retried).
    private func lookup(_ account: String) -> Lookup {
        lock.withLock {
            if let known = cache[account] { return .value(known) }
            switch secrets.fetch(service: Self.service, account: account) {
            case .found(let data):
                let value = String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
                cache[account] = .some(value)
                return .value(value)
            case .missing:
                cache[account] = .some(nil)
                return .value(nil)
            case .failed:
                return .failed
            }
        }
    }

    /// Saves (trimmed) or, for nil or empty, removes.
    public func setSecret(_ account: String, _ raw: String?) {
        let value = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        secrets.delete(service: Self.service, account: account)
        if !value.isEmpty { _ = secrets.write(service: Self.service, account: account, data: Data(value.utf8)) }
        lock.withLock { cache[account] = .some(value.isEmpty ? nil : value) }
    }

    /// The URL typed in Settings, if any.
    public var customURL: String? { secret(Self.urlKey) }

    public var url: String { customURL ?? gateway.defaultURL }

    /// GOWA's `user:pass` or OpenWA's API key. For GOWA, the first Kobe link's password when none was set: copied
    /// to `whatsapp-api-key` once (a credential cleared later in Settings stays cleared). A credential the Keychain
    /// failed to read is neither replaced by the old password nor overwritten by it.
    public var credential: String? {
        guard case .value(let set) = lookup(Self.credentialKey) else { return nil }
        if let set { return set }
        guard gateway == .gowa, !defaults.bool(forKey: "whatsappCredentialMigrated"),
              let legacy = secret(Self.legacyAuthKey) else { return nil }
        setSecret(Self.credentialKey, legacy)
        defaults.set(true, forKey: "whatsappCredentialMigrated")
        return legacy
    }

    /// The webhook's signing secret, made once (random, 64 hex characters).
    public func webhookSecret() -> String {
        if let s = secret(Self.secretKey), s.count >= 16 { return s }
        var generator = SystemRandomNumberGenerator()
        let s = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }).waHex
        setSecret(Self.secretKey, s)
        return s
    }

    public var webhookURL: String { "http://127.0.0.1:\(port)\(WAWebhook.path)" }

    /// The provider for the chosen gateway; nil when the URL isn't http(s).
    public func makeProvider(session: URLSession? = nil) -> (any WhatsAppProvider)? {
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)), base.scheme?.hasPrefix("http") == true,
              base.host != nil else { return nil }
        switch gateway {
        case .gowa: return GOWAProvider(base: base, basicAuth: credential, session: session)
        case .openwa: return OpenWAProvider(base: base, apiKey: credential, session: session)
        }
    }

    /// What GOWA is started with, when Kobe may start it: on this Mac only, an executable binary, the gateway GOWA.
    /// nil means "don't run it" (it is stopped if Kobe started it).
    public func launchPlan() -> (binary: String, arguments: [String], environment: [String: String], signature: String)? {
        guard autoStart, gateway == .gowa else { return nil }
        let path = (binaryPath as NSString).expandingTildeInPath
        guard !path.isEmpty, isExecutable(path), let url = URL(string: url) else { return nil }
        // Only ever on this Mac: an address elsewhere is someone else's gateway.
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { return nil }
        // Never without a password: GOWA's API can read and send everything, so a missing or unusable credential
        // is replaced by a random one (stored, so Kobe's own calls use it too).
        var credential = self.credential ?? ""
        if !credential.contains(":") {
            var generator = SystemRandomNumberGenerator()
            credential = "kobe:" + Data((0..<24).map { _ in UInt8.random(in: 0...255, using: &generator) }).waHex
            setSecret(Self.credentialKey, credential)
        }
        var env: [String: String] = [:]
        // The credential goes through the environment, not the command line (`ps` shows that).
        env["APP_BASIC_AUTH"] = credential
        // GOWA's own web dashboard is not needed (Kobe is the interface): it would fetch itself from GitHub.
        env["APP_UI_ENABLED"] = "false"
        let signature = [path, url.absoluteString, credential].joined(separator: "\u{1F}")
        return (path, WAGOWA.launchArguments(for: url), env, signature)
    }
}

/// The rule for the GOWA it starts: left alone while it runs with the same settings, restarted when its binary,
/// address or password changed, and a GOWA that keeps dying started again once a minute at most.
public enum WAGOWARestart {
    public enum Action: Equatable, Sendable { case keep, restart, start, wait }

    public static func decide(running: Bool, launchedWith: String?, signature: String, lastStart: Date,
                              now: Date = Date()) -> Action {
        if running { return launchedWith == signature ? .keep : .restart }
        if launchedWith == signature, now.timeIntervalSince(lastStart) < 60 { return .wait }
        return .start
    }
}
