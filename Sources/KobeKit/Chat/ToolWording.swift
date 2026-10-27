import Foundation

/// Plain words for the tools Kobe uses while it works, shown as the chat's status ("searching the web…").
public enum ToolWording {
    public static let thinking = "thinking…"

    /// First match wins, so more specific names (memory_search) sit above broader ones (search).
    private static let table: [(keys: [String], phrase: String, short: String)] = [
        (["memory"], "checking memory…", "memory"),
        (["kobe-mac-snapshots", "mail"], "reading your inbox…", "your inbox"),
        (["calendar"], "checking your calendar…", "your calendar"),
        (["browser"], "opening a page…", "a page"),
        (["terminal", "bash", "shell"], "running a command…", "a command"),
        (["read_file", "file_read"], "reading a file…", "a file"),
        (["search_files", "file_search"], "searching files…", "files"),
        (["session_search"], "searching past chats…", "past chats"),
        (["web_search", "search"], "searching the web…", "web search"),
    ]

    private static func entry(_ name: String) -> (phrase: String, short: String)? {
        let lower = name.lowercased()
        for row in table where row.keys.contains(where: { lower.contains($0) }) {
            return (row.phrase, row.short)
        }
        return nil
    }

    private static func spaced(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    public static func phrase(name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return thinking }
        return entry(name)?.phrase ?? "using \(spaced(name))…"
    }

    public static func short(name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "a tool" }
        return entry(name)?.short ?? spaced(name)
    }
}
