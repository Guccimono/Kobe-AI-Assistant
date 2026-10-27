import Foundation

public enum DropRefusal: Equatable, Sendable {
    case folder, tooLarge, unreadable

    public var message: String {
        switch self {
        case .folder: "Folders can't be dropped yet. Drop the files inside."
        case .tooLarge: "Over 200 MB."
        case .unreadable: "Couldn't read it."
        }
    }
}

public struct RefusedDrop: Equatable, Sendable {
    public let name: String
    public let reason: DropRefusal
    public init(name: String, reason: DropRefusal) {
        self.name = name
        self.reason = reason
    }
}

public struct DropResult: Equatable, Sendable {
    public var copied: [URL] = []
    public var refused: [RefusedDrop] = []
}

/// Hands dropped files to Kobe: copies them into the exchange folder the engine reads
/// (`<root>/inbox/<yyyy-MM-dd>/`), readable by the group, never half-written. Nothing else of yours is exposed.
public struct DropBox: Sendable {
    public static let maxBytes = 200 * 1024 * 1024

    public let root: URL
    private let now: @Sendable () -> Date

    public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    public func accept(_ urls: [URL]) -> DropResult {
        let fm = FileManager.default
        var result = DropResult()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let inbox = root.appendingPathComponent("inbox").appendingPathComponent(formatter.string(from: now()))
        for url in urls {
            let name = url.lastPathComponent
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), fm.isReadableFile(atPath: url.path) else {
                result.refused.append(RefusedDrop(name: name, reason: .unreadable)); continue
            }
            if isDirectory.boolValue { result.refused.append(RefusedDrop(name: name, reason: .folder)); continue }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > Self.maxBytes { result.refused.append(RefusedDrop(name: name, reason: .tooLarge)); continue }
            let temporary = inbox.appendingPathComponent(".\(UUID().uuidString).partial")
            do {
                try makeFolder(inbox)
                let destination = Self.free(name: name, in: inbox)
                try fm.copyItem(at: url, to: temporary)
                try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: temporary.path)
                try fm.moveItem(at: temporary, to: destination)
                result.copied.append(destination)
            } catch {
                try? fm.removeItem(at: temporary)  // never leave a half-copied file behind
                result.refused.append(RefusedDrop(name: name, reason: .unreadable))
            }
        }
        return result
    }

    /// The message that tells Kobe where the files are.
    public static func message(for copied: [URL], text: String?) -> String {
        var parts: [String] = []
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { parts.append(text) }
        if !copied.isEmpty {
            parts.append((["Files I dropped for you (in the exchange folder):"] + copied.map { "- \($0.path)" }).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private func makeFolder(_ inbox: URL) throws {
        let fm = FileManager.default
        for folder in [inbox.deletingLastPathComponent(), inbox] where !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o750], ofItemAtPath: folder.path)
        }
    }

    /// `name.ext`, else `name 2.ext`, `name 3.ext` …
    static func free(name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
