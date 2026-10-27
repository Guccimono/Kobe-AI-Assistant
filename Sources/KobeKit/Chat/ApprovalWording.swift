import Foundation

/// A plain one-line guess at what a command Kobe wants to run will do, shown beside Allow / Deny.
public enum ApprovalWording {
    public static func summary(command: String?, description: String?) -> String {
        if let d = description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        let raw = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Looks like it will do something that needs your OK."
        if raw.isEmpty { return fallback }

        if raw.contains("tell application") || firstToken(of: stripped(raw)) == "osascript" {
            if let app = quotedApp(in: raw) { return "Looks like it will control \(app)." }
            return "Looks like it will control an app."
        }
        let words = stripped(raw).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = words.first else { return fallback }
        let second = words.count > 1 ? words[1] : ""
        switch first {
        case "rm", "rmdir": return "Looks like it will delete files."
        case "git" where second == "push": return "Looks like it will push code."
        case "git" where second == "commit": return "Looks like it will commit changes."
        case "curl", "wget":
            if pipesToShell(raw) {
                if let host = urlHost(in: raw) { return "Looks like it will download and run a script from \(host)." }
                return "Looks like it will download and run a script."
            }
            if let host = urlHost(in: raw) { return "Looks like it will download from \(host)." }
            return "Looks like it will download something."
        case _ where ["pip", "pip3", "npm", "brew", "uv"].contains(first) && second == "install":
            return "Looks like it will install software."
        case "open": return "Looks like it will open something."
        case "python", "python3", "node", "swift", "ruby": return "Looks like it will run a script."
        default: return "Looks like it will run `\(first)`."
        }
    }

    public static func denyLine(copy: Copy) -> String {
        "Deny stops this step; \(copy.name) tells you what it skipped."
    }

    private static func firstToken(of s: String) -> String? {
        s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    /// Drops leading `sudo`, `env VAR=x` and `cd … &&`, repeatedly.
    private static func stripped(_ command: String) -> String {
        var s = command
        while true {
            let before = s
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("sudo ") { s = String(s.dropFirst(5)) }
            else if s.hasPrefix("env ") {
                var words = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                words.removeFirst()
                while let w = words.first, isAssignment(w) { words.removeFirst() }
                s = words.joined(separator: " ")
            } else if s.hasPrefix("cd "), let r = s.range(of: "&&") {
                s = String(s[r.upperBound...])
            }
            if s == before { return s }
        }
    }

    private static func isAssignment(_ w: String) -> Bool {
        guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
        return w[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `… | sh`, `| bash`, `| zsh`, also behind `sudo` or `env`.
    private static func pipesToShell(_ command: String) -> Bool {
        command.range(of: #"\|\s*(sudo\s+)?(env\s+(\w+=\S*\s+)*)?(/\S*/)?(sh|bash|zsh)(\s|$)"#, options: .regularExpression) != nil
    }

    private static func urlHost(in command: String) -> String? {
        guard let r = command.range(of: #"https?://[^\s'"|;&)]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(command[r]))?.host
    }

    private static func quotedApp(in command: String) -> String? {
        guard let r = command.range(of: #"tell application \\?"([^"\\]+)\\?""#, options: .regularExpression) else { return nil }
        let match = String(command[r])
        guard let a = match.firstIndex(of: "\""), let b = match.lastIndex(of: "\""), a < b else { return nil }
        let name = match[match.index(after: a)..<b].trimmingCharacters(in: CharacterSet(charactersIn: "\\\""))
        return name.isEmpty ? nil : name
    }
}
