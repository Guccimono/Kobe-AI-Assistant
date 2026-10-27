import Foundation

/// Where the exchange folder is and how its files are shared: one setting for drops, snapshots, requests and results.
public struct ExchangeSettings: Equatable, Sendable {
    public var folder: String
    /// Two-user mode: the engine runs as another macOS user in group `staff`, so everything is group-writable.
    public var shared: Bool

    public init(folder: String, shared: Bool) {
        self.folder = folder
        self.shared = shared
    }

    /// `~/Library/Application Support/Kobe/exchange`.
    public static var defaultFolder: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(Brand.dataFolderName)/exchange", isDirectory: true).path
    }

    /// Two-user mode's default: a folder both macOS users can reach.
    public static let sharedFolder = "/Users/Shared/hermes-exchange"
}

/// The folder the app and the engine exchange files through. By default both are the same macOS user and it lives in
/// the app's own Application Support folder; two-user mode (opt-in) shares it with another user through group `staff`.
public enum SnapshotFolder {
    private static let current = NSLockedBox(ExchangeSettings(folder: ExchangeSettings.defaultFolder, shared: false))

    /// Set once at launch (`AppModel.init`) and again if the setting changes.
    public static func configure(_ settings: ExchangeSettings) { current.value = settings }
    public static var settings: ExchangeSettings { current.value }
    public static var shared: Bool { settings.shared }

    /// `KOBE_EXCHANGE_ROOT` wins (tests, `--demo`); otherwise the configured folder.
    public static func root(for settings: ExchangeSettings,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["KOBE_EXCHANGE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: settings.folder)
    }

    public static var root: URL { root(for: settings) }
    public static var widgets: URL { widgets(in: root) }
    public static var requests: URL { requests(in: root) }
    public static var results: URL { results(in: root) }

    public static func url(_ id: WidgetID) -> URL { url(id, in: root) }

    /// The same paths under a given root (an injected one: the app's tests use one temp folder each).
    public static func widgets(in root: URL) -> URL { root.appendingPathComponent("widgets") }
    public static func requests(in root: URL) -> URL { root.appendingPathComponent("requests") }
    public static func results(in root: URL) -> URL { root.appendingPathComponent("results") }
    public static func url(_ id: WidgetID, in root: URL) -> URL { widgets(in: root).appendingPathComponent("\(id.rawValue).json") }

    /// Same user (`shared` false): folders 0755, files 0644. Two-user mode: both users write here, so folders are 2770
    /// (setgid, so new files keep the folder's group) with group `staff`, files 0660. Creates the folder, or repairs
    /// the mode of one this user owns; someone else's is left alone.
    public static func prepare(_ folder: URL, shared: Bool = SnapshotFolder.shared) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        guard let attributes = try? fm.attributesOfItem(atPath: folder.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return }
        if shared, let staff = getgrnam("staff")?.pointee.gr_gid,
           (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value != staff {
            _ = chown(folder.path, uid_t.max, staff)
        }
        let mode: mode_t = shared ? 0o2770 : 0o755
        if (attributes[.posixPermissions] as? NSNumber)?.intValue != Int(mode) {
            _ = chmod(folder.path, mode)
        }
    }

    /// Temp file in the same folder with the final mode, then rename(2): a reader sees the old file or the new one,
    /// never half of one, and the mode never comes from the file being replaced.
    public static func writeAtomically(_ data: Data, to url: URL, shared: Bool = SnapshotFolder.shared) throws {
        let folder = url.deletingLastPathComponent()
        prepare(folder, shared: shared)
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            guard chmod(temp.path, shared ? 0o660 : 0o644) == 0, rename(temp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

/// A value behind a lock: the one place the configured settings live, readable from any thread.
final class NSLockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
