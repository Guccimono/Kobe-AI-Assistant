import Foundation

/// A Notes body (HTML) as text the notch can edit, and back. Only what survives the round trip is editable: a title
/// (heading, bold or plain), plain lines, empty lines and bulleted lists ("- " lines). Anything else (styled words,
/// links, tables, checklists, attributes, attachments, a lock) leaves the note read-only, so a save never drops it.
public struct NoteDocument: Equatable, Sendable {
    public enum TitleStyle: Equatable, Sendable { case heading, bold, plain }
    public enum ReadOnly: Error, Equatable, Sendable { case locked, attachments, formatting }

    public var titleStyle: TitleStyle
    /// The title line, then the body; list items start with "- ".
    public var text: String

    public static func parse(html: String, attachments: Int, locked: Bool) -> Result<NoteDocument, ReadOnly> {
        if locked { return .failure(.locked) }
        if attachments > 0 { return .failure(.attachments) }
        var lines: [String] = []
        var line = ""
        var open = false
        var inItem = false
        var style = TitleStyle.plain
        var styled: String?
        /// The last thing was a break that ended a line: a block closing right after it adds no empty line.
        var broke = false
        func push() { lines.append(line); line = ""; open = false }

        var rest = Substring(html)
        while !rest.isEmpty {
            guard let lt = rest.firstIndex(of: "<") else { line += decode(rest); open = true; rest = ""; break }
            let text = rest[..<lt]
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || open { line += decode(text) }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { open = true }
            guard let gt = rest[lt...].firstIndex(of: ">") else { return .failure(.formatting) }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { broke = false }
            let tag = rest[rest.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[rest.index(after: gt)...]
            let closing = tag.hasPrefix("/")
            let name = closing ? String(tag.dropFirst()) : tag.hasSuffix("/") ? String(tag.dropLast()) : tag
            switch (name, closing) {
            case ("div", false): if open, !line.isEmpty { push() }; open = true
            case ("div", true):
                if broke, line.isEmpty { open = false } else if open || !line.isEmpty { push() }
            case ("br", false):
                // An empty bullet is "<li><br></li>": the bullet alone.
                if inItem, line == "- " { break }
                if !line.isEmpty { push(); open = true; broke = true; continue } else { open = true }
            case ("ul", _): if !line.isEmpty { push() }
            case ("li", false): line = "- "; inItem = true; open = true
            case ("li", true): push(); inItem = false
            case ("h1", false), ("b", false):
                // Only the title may be styled, and only as a whole.
                guard lines.isEmpty, line.isEmpty, !inItem, styled == nil else { return .failure(.formatting) }
                styled = name
                style = name == "h1" ? .heading : .bold
            case ("h1", true), ("b", true):
                guard styled == name else { return .failure(.formatting) }
            default:
                return .failure(.formatting)
            }
            if name != "b", name != "h1" { broke = false }
        }
        if !line.isEmpty { lines.append(line) }
        return .success(NoteDocument(titleStyle: style, text: lines.joined(separator: "\n")))
    }

    /// The edited text as a Notes body: the title in its style, "- " lines as one list, empty lines as Notes' own.
    public func html(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let title = Self.escape(lines.isEmpty ? "" : lines.removeFirst())
        var out = switch titleStyle {
        case .heading: "<div><h1>\(title)</h1></div>"
        case .bold: "<div><b>\(title)</b></div>"
        case .plain: "<div>\(title)</div>"
        }
        var inList = false
        for line in lines {
            let item = line.hasPrefix("- ") || line.hasPrefix("• ")
            if item, !inList { out += "<ul>"; inList = true }
            if !item, inList { out += "</ul>"; inList = false }
            if item {
                let content = Self.escape(String(line.dropFirst(2)))
                out += content.isEmpty ? "<li><br></li>" : "<li>\(content)</li>"
            } else if line.isEmpty {
                out += "<div><br></div>"
            } else {
                out += "<div>\(Self.escape(line))</div>"
            }
        }
        if inList { out += "</ul>" }
        return out
    }

    // MARK: Helpers

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func decode(_ s: Substring) -> String {
        var t = String(s).replacingOccurrences(of: "\n", with: "")
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                               ("&apos;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return t
    }
}
