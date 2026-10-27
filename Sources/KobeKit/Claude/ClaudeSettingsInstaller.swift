import Foundation

/// What installing (or removing) Kobe's hooks would do to `~/.claude/settings.json`, shown before anything is written.
public struct ClaudeSettingsPlan: Equatable, Sendable {
    public let original: String
    public let updated: String
    public let removedCommands: [String]
    public let addedEvents: [String]

    public init(original: String, updated: String, removedCommands: [String], addedEvents: [String]) {
        self.original = original
        self.updated = updated
        self.removedCommands = removedCommands
        self.addedEvents = addedEvents
    }
}

/// Puts Kobe's hook into Claude Code's settings, replacing the old Kobe one. Every
/// unrelated key and hook is kept. Nothing is written without a dated backup and a plan the user has seen.
public enum ClaudeSettingsInstaller {
    public enum InstallerError: Error, Equatable {
        case malformed
        case changedSinceShown
    }

    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                                "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "SessionEnd"]

    /// Commands that belong to notch apps this one replaces.
    static let replaced = ["Kobe.app/Contents/MacOS/kobe-hook"]

    public static func plan(settings: String?, hookPath: String, wait: Int) throws -> ClaudeSettingsPlan {
        var root = try parse(settings)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let removed = strip(&hooks) { command in command.contains(hookPath) || replaced.contains { command.contains($0) } }
        let quoted = "\"\(hookPath)\""
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let timeout = event == "PermissionRequest" ? wait + 5 : 5
            groups.append(["hooks": [["type": "command", "command": quoted, "timeout": timeout]]])
            if event == "PreToolUse" {
                groups.append(["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": quoted + " --ask", "timeout": wait + 5]]])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return ClaudeSettingsPlan(original: settings ?? "", updated: try render(root), removedCommands: removed, addedEvents: events)
    }

    public static func uninstallPlan(settings: String, hookPath: String) throws -> ClaudeSettingsPlan {
        var root = try parse(settings)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let removed = strip(&hooks) { $0.contains(hookPath) }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return ClaudeSettingsPlan(original: settings, updated: try render(root), removedCommands: removed, addedEvents: [])
    }

    /// Writes the plan: first a dated backup of the current file (when there is one), then the new file atomically.
    /// Refuses if the file changed since the plan was made. Returns the backup's location.
    @discardableResult
    public static func apply(_ plan: ClaudeSettingsPlan, to url: URL, now: Date) throws -> URL? {
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard current == plan.original else { throw InstallerError.changedSinceShown }
        var backup: URL?
        if FileManager.default.fileExists(atPath: url.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let target = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".kobe-backup-" + formatter.string(from: now))
            try FileManager.default.copyItem(at: url, to: target)
            backup = target
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try plan.updated.write(to: url, atomically: true, encoding: .utf8)
        return backup
    }

    /// A line diff for the confirmation sheet: "- " removed, "+ " added, "  " unchanged.
    public static func diff(_ plan: ClaudeSettingsPlan) -> String {
        let a = plan.original.isEmpty ? [] : plan.original.components(separatedBy: "\n")
        let b = plan.updated.components(separatedBy: "\n")
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                out.append("  " + a[i]); i += 1; j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                out.append("+ " + b[j]); j += 1
            } else {
                out.append("- " + a[i]); i += 1
            }
        }
        return out.joined(separator: "\n")
    }

    /// The wait the installed hooks were written for (their PermissionRequest timeout minus 5 s), or nil when Kobe's
    /// hooks aren't there. A different value from the current setting means the hooks need re-installing.
    public static func installedWait(settings: String, hookPath: String) -> Int? {
        guard let root = try? parse(settings), let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["PermissionRequest"] as? [[String: Any]] else { return nil }
        for group in groups {
            for entry in group["hooks"] as? [[String: Any]] ?? [] {
                if let command = entry["command"] as? String, command.contains(hookPath), let timeout = entry["timeout"] as? Int {
                    return timeout - 5
                }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func parse(_ settings: String?) throws -> [String: Any] {
        guard let settings, !settings.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any] else {
            throw InstallerError.malformed
        }
        return object
    }

    private static func render(_ root: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes every hook whose command matches; drops groups and events left empty. Returns the removed commands.
    private static func strip(_ hooks: inout [String: Any], where matches: (String) -> Bool) -> [String] {
        var removed: [String] = []
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var group in groups {
                let entries = group["hooks"] as? [[String: Any]] ?? []
                let keep = entries.filter { entry in
                    guard let command = entry["command"] as? String, matches(command) else { return true }
                    removed.append(command)
                    return false
                }
                if keep.isEmpty && !entries.isEmpty { continue }
                group["hooks"] = keep
                kept.append(group)
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        return removed
    }
}
