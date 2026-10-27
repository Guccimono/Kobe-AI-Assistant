import Foundation

/// Pure text edits for Hermes's `config.yaml` and `.env`. No I/O: callers read and write the files.
public enum HermesConfig {
    // MARK: config.yaml

    /// Returns nil, writing nothing, when `gateway` or `api_server` exists with an inline value (`{}`, `null`):
    /// adding a block would duplicate the key, so the caller shows the person what to set instead.
    /// Minimal YAML handling for the one block Kobe owns. Edits `api_server` in place wherever Hermes accepts it
    /// (`gateway.api_server`, `gateway.platforms.api_server`, top-level `platforms.api_server`), replacing its four
    /// keys and keeping any others under it; with none present, adds `gateway.api_server`. Every other line stays
    /// byte for byte. A nil `key` keeps the block's own key line (enabled, host and port are still set).
    public static func mergeApiServer(into yaml: String, host: String, port: Int, key: String?) -> String? {
        var lines = split(yaml).0
        if hasInlineConflict(lines) { return nil }
        let eol = lineEnding(yaml)
        var wanted: [(String, String)] = [("enabled", "true"), ("host", host), ("port", String(port))]
        if let key { wanted.append(("key", key)) }

        if let block = findApiServer(lines) {
            let childIndent = block.childIndent
            var body = Array(lines[(block.start + 1)..<block.end])
            var seen = Set<String>()
            var rebuilt: [String] = []
            for line in body {
                if let name = childKey(line, indent: childIndent), let value = wanted.first(where: { $0.0 == name })?.1 {
                    if seen.insert(name).inserted {
                        rebuilt.append(String(repeating: " ", count: childIndent) + "\(name): \(value)")
                    }
                    // a duplicate of one of the four keys is dropped
                } else {
                    rebuilt.append(line)
                }
            }
            body = rebuilt
            for (name, value) in wanted where !seen.contains(name) {
                body.append(String(repeating: " ", count: childIndent) + "\(name): \(value)")
            }
            lines.replaceSubrange((block.start + 1)..<block.end, with: body)
        } else {
            let gw = topLevelBlock(lines, key: "gateway")
            let step = gw?.childIndent ?? 2   // the file's own unit: gateway sits at column 0
            let pad = String(repeating: " ", count: step)
            let apiLines = [pad + "api_server:"] + wanted.map { pad + pad + "\($0.0): \($0.1)" }
            if let gw {
                lines.insert(contentsOf: apiLines, at: gw.end)
            } else {
                lines.append(contentsOf: ["gateway:"] + apiLines)
            }
        }
        return lines.joined(separator: eol) + eol
    }

    /// Reads Kobe's block back. `nil` when no `api_server` block exists in any of the three accepted places.
    public static func apiServer(in yaml: String) -> (enabled: Bool, host: String?, port: Int?, hasKey: Bool)? {
        let (lines, _) = split(yaml)
        guard let block = findApiServer(lines) else { return nil }
        var values: [String: String] = [:]
        for i in (block.start + 1)..<block.end {
            guard let name = childKey(lines[i], indent: block.childIndent), values[name] == nil else { continue }
            values[name] = scalar(afterKeyIn: lines[i])
        }
        let enabled = values["enabled"].map { ["true", "yes", "on"].contains($0.lowercased()) } ?? false
        let host = values["host"].flatMap { $0.isEmpty ? nil : $0 }
        let port = values["port"].flatMap { Int($0) }
        return (enabled, host, port, !(values["key"] ?? "").isEmpty)
    }

    // MARK: .env

    /// The brain whose door is already open in an `.env` file: the first match of `ANTHROPIC_API_KEY`,
    /// `OPENAI_BASE_URL` (the Ollama pair also sets `OPENAI_API_KEY`, so it is checked first), `OPENAI_API_KEY`,
    /// `OPENROUTER_API_KEY`, with a non-empty value. Empty and commented-out lines do not count.
    public static func hasProviderKey(env: String) -> Brain? {
        let values = envValues(env)
        func has(_ k: String) -> Bool { !(values[k] ?? "").isEmpty }
        if has("ANTHROPIC_API_KEY") { return .claude }
        if has("OPENAI_BASE_URL") { return .ollama }
        if has("OPENAI_API_KEY") { return .openai }
        if has("OPENROUTER_API_KEY") { return .openrouter }
        return nil
    }

    /// Replaces the first `KEY=…` line, or adds one at the end. A commented-out `# KEY=…` is left alone.
    /// Every other line is kept; a trailing newline is kept, and added when the input was empty.
    public static func setEnv(_ env: String, key: String, value: String) -> String {
        if env.isEmpty { return "\(key)=\(value)\n" }
        let eol = lineEnding(env)
        var (lines, trailing) = split(env)
        let new = "\(key)=\(value)"
        if let i = lines.firstIndex(where: { envKey($0) == key }) {
            lines[i] = new
        } else {
            lines.append(new)
        }
        return lines.joined(separator: eol) + (trailing ? eol : "")
    }

    /// Removes every `KEY=…` line; everything else (comments included) stays. Unchanged when the key is absent.
    public static func removeEnv(_ env: String, key: String) -> String {
        if env.isEmpty { return env }
        let eol = lineEnding(env)
        let (lines, trailing) = split(env)
        let kept = lines.filter { envKey($0) != key }
        if kept.count == lines.count { return env }
        return kept.joined(separator: eol) + (trailing && !kept.isEmpty ? eol : "")
    }

    /// The (unquoted) value of the first `KEY=…` line, nil when there is none.
    public static func envValue(_ env: String, key: String) -> String? { envValues(env)[key] }

    // MARK: key and commands

    /// 32 random bytes, base64url without padding: 43 characters.
    public static func newEngineKey(random: (Int) -> Data = { n in
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }) -> String {
        random(32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `["hermes","config","set",key,value]` for each pair. The caller must never pass a secret here: argv is
    /// visible to other processes. Secrets go through `setEnv` or stdin. This function does not check.
    public static func configSetCommands(_ pairs: [(key: String, value: String)]) -> [[String]] {
        pairs.map { ["hermes", "config", "set", $0.key, $0.value] }
    }

    // MARK: helpers

    private static func split(_ text: String) -> ([String], Bool) {
        if text.isEmpty { return ([], false) }
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let trailing = lines.last == ""
        if trailing { lines.removeLast() }
        return (lines, trailing)
    }

    private static func lineEnding(_ text: String) -> String { text.contains("\r\n") ? "\r\n" : "\n" }

    private static func inline(_ lines: [String], key: String, indent want: Int, in range: Range<Int>) -> Bool {
        range.contains { i in
            indent(lines[i]) == want && !isBlankOrComment(lines[i]) && mappingKey(lines[i]) == key
                && !scalar(afterKeyIn: lines[i]).isEmpty
        }
    }

    private static func hasInlineConflict(_ lines: [String]) -> Bool {
        if inline(lines, key: "gateway", indent: 0, in: 0..<lines.count) { return true }
        if inline(lines, key: "platforms", indent: 0, in: 0..<lines.count) == false,
           let p = topLevelBlock(lines, key: "platforms"),
           inline(lines, key: "api_server", indent: p.childIndent, in: (p.start + 1)..<p.end) { return true }
        if let gw = topLevelBlock(lines, key: "gateway") {
            let r = (gw.start + 1)..<gw.end
            if inline(lines, key: "api_server", indent: gw.childIndent, in: r) { return true }
            if let p = child(lines, of: gw, key: "platforms"),
               inline(lines, key: "api_server", indent: p.childIndent, in: (p.start + 1)..<p.end) { return true }
        }
        return false
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("#")
    }

    /// The key name of a mapping line at exactly `indent`, or nil.
    private static func childKey(_ line: String, indent want: Int) -> String? {
        guard indent(line) == want, !isBlankOrComment(line) else { return nil }
        return mappingKey(line)
    }

    private static func mappingKey(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = t.firstIndex(of: ":") else { return nil }
        let after = t[t.index(after: colon)...]
        guard after.isEmpty || after.first == " " else { return nil }
        let name = t[..<colon].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Text after `key:` with a trailing ` # comment` and quotes removed.
    private static func scalar(afterKeyIn line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("#") { return "" }
        if let q = v.first, q == "\"" || q == "'" {
            if let close = v.dropFirst().firstIndex(of: q) { return String(v[v.index(after: v.startIndex)..<close]) }
            return String(v.dropFirst())
        }
        if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return v
    }

    private struct Block { var start: Int; var end: Int; var indent: Int; var childIndent: Int }

    /// The block of `key:` at `indent` within `range`; `end` excludes trailing blank and comment lines.
    private static func block(_ lines: [String], key: String, indent want: Int, in range: Range<Int>) -> Block? {
        for i in range where indent(lines[i]) == want && !isBlankOrComment(lines[i]) && mappingKey(lines[i]) == key {
            let rest = scalar(afterKeyIn: lines[i])
            if !rest.isEmpty { return nil }   // inline value such as `{}`: not a block we can edit
            var end = i + 1
            var last = i + 1
            var child: Int?
            while end < range.upperBound {
                let l = lines[end]
                if !isBlankOrComment(l) {
                    if indent(l) <= want { break }
                    if child == nil { child = indent(l) }
                    last = end + 1
                }
                end += 1
            }
            return Block(start: i, end: last, indent: want, childIndent: child ?? want + 2)
        }
        return nil
    }

    private static func topLevelBlock(_ lines: [String], key: String) -> Block? {
        block(lines, key: key, indent: 0, in: 0..<lines.count)
    }

    private static func child(_ lines: [String], of parent: Block, key: String) -> Block? {
        block(lines, key: key, indent: parent.childIndent, in: (parent.start + 1)..<parent.end)
    }

    private static func findApiServer(_ lines: [String]) -> Block? {
        if let gw = topLevelBlock(lines, key: "gateway") {
            if let b = child(lines, of: gw, key: "api_server") { return b }
            if let p = child(lines, of: gw, key: "platforms"), let b = child(lines, of: p, key: "api_server") { return b }
        }
        if let p = topLevelBlock(lines, key: "platforms"), let b = child(lines, of: p, key: "api_server") { return b }
        return nil
    }

    private static func envKey(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        var name = t[..<eq].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("export ") { name = String(name.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return name
    }

    private static func envValues(_ env: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in env.components(separatedBy: "\n") {
            guard let k = envKey(line), out[k] == nil else { continue }
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            var v = String(t[t.index(after: t.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
            out[k] = v
        }
        return out
    }
}
