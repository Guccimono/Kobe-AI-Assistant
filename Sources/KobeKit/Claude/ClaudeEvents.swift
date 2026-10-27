import Foundation

/// One permission question from Claude Code, shown in full.
public struct ClaudePermission: Equatable, Sendable {
    public let tool: String
    public let project: String
    /// "Run a command", "Edit a file", …
    public let title: String
    /// The whole command or input, never shortened; hidden characters made visible.
    public let body: String
    /// Claude's description of the command.
    public let detail: String?
}

/// A question Claude Code asks with AskUserQuestion. `question` and `options` are for the screen (hidden characters
/// made visible); `rawQuestion` and `rawOptions` are Claude Code's own bytes, the only ones it accepts back as the
/// answer's key and value. When the prompt holds several questions (`count` > 1) the notch shows the first and the
/// answer is left to Claude Code.
public struct ClaudeQuestion: Equatable, Sendable {
    public let project: String
    public let question: String
    public let options: [String]
    public let rawQuestion: String
    public let rawOptions: [String]
    public let count: Int

    /// Builds from Claude Code's text as sent; the shown text is derived.
    public init(project: String, rawQuestion: String, rawOptions: [String], count: Int = 1) {
        self.project = project
        self.rawQuestion = rawQuestion
        self.rawOptions = rawOptions
        self.question = ClaudeText.visible(rawQuestion)
        self.options = rawOptions.map(ClaudeText.visible)
        self.count = count
    }

    /// A question whose text is already the one to show (and to send back).
    public init(project: String, question: String, options: [String]) {
        self.init(project: project, rawQuestion: question, rawOptions: options)
    }

    /// The option's wire label for the one shown, nil when the text isn't one of the options.
    public func rawLabel(for shown: String) -> String? {
        options.firstIndex(of: shown).map { rawOptions[$0] }
    }
}

/// What Claude Code is doing, for the notch's left wing.
public enum ClaudeStep: Equatable, Sendable {
    case thinking, reading, searching, editing, running, web, delegating, working

    public init(tool: String) {
        switch tool {
        case "Read", "NotebookRead": self = .reading
        case "Grep", "Glob", "LS", "ToolSearch": self = .searching
        case "Edit", "Write", "MultiEdit", "NotebookEdit": self = .editing
        case "Bash", "BashOutput", "KillShell", "Monitor": self = .running
        case "WebFetch", "WebSearch": self = .web
        case "Task", "Agent": self = .delegating
        default: self = .working
        }
    }

    public var label: String {
        switch self {
        case .thinking: "Thinking"
        case .reading: "Reading"
        case .searching: "Searching"
        case .editing: "Editing"
        case .running: "Running a command"
        case .web: "On the web"
        case .delegating: "Delegating"
        case .working: "Working"
        }
    }

    public var icon: PhosphorIcon {
        switch self {
        case .running: .terminalWindowFill
        case .web: .appWindow
        case .searching: .magnifyingGlass
        default: .sparkleFill
        }
    }
}

/// A Claude Code hook event, as kobe-hook forwards it.
public enum ClaudeEvent: Equatable, Sendable {
    case sessionStarted(project: String)
    case step(project: String, step: ClaudeStep)
    case finished(project: String, app: String?)
    case permission(ClaudePermission)
    case question(ClaudeQuestion)
    case ended(project: String)

    /// Whether the hook is waiting for an answer from the notch.
    public var waitsForAnswer: Bool {
        switch self {
        case .permission, .question: true
        default: false
        }
    }

    public static func parse(_ data: Data) -> ClaudeEvent? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = json["hook_event_name"] as? String else { return nil }
        let project = ((json["cwd"] as? String).map { ($0 as NSString).lastPathComponent }).map(ClaudeText.visible) ?? "Claude Code"
        let tool = json["tool_name"] as? String ?? ""
        let input = json["tool_input"] as? [String: Any] ?? [:]
        switch name {
        case "SessionStart":
            return .sessionStarted(project: project)
        case "UserPromptSubmit":
            return .step(project: project, step: .thinking)
        case "PreToolUse" where tool == "AskUserQuestion" && json["_ask"] as? Bool == true:
            guard let questions = input["questions"] as? [[String: Any]], let first = questions.first,
                  let question = first["question"] as? String else { return nil }
            let options = (first["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return .question(ClaudeQuestion(project: project, rawQuestion: question, rawOptions: options, count: questions.count))
        case "PreToolUse" where tool == "AskUserQuestion":
            return .step(project: project, step: .working)  // the --ask hook carries the question
        case "PreToolUse":
            return .step(project: project, step: ClaudeStep(tool: tool))
        case "PermissionRequest":
            return .permission(ClaudeText.describe(tool: tool, input: input, project: project))
        case "Stop":
            return .finished(project: project, app: ClaudeText.appName(termProgram: json["_term_program"] as? String))
        case "SessionEnd":
            return .ended(project: project)
        default:
            return nil
        }
    }
}

/// Turning hook input into text a person can trust.
public enum ClaudeText {
    public static func describe(tool rawTool: String, input: [String: Any], project: String) -> ClaudePermission {
        let tool = visible(rawTool)
        let detail = (input["description"] as? String).map(visible)
        switch rawTool {
        case "Bash":
            // Anything besides the command and its description is shown too: nothing that affects what runs is hidden.
            var rest = input
            rest.removeValue(forKey: "command")
            rest.removeValue(forKey: "description")
            let command = visible(input["command"] as? String ?? "")
            return ClaudePermission(tool: tool, project: project, title: "Run a command",
                                    body: rest.isEmpty ? command : command + "\n\n" + pretty(rest), detail: detail)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? ""
            var rest = input
            rest.removeValue(forKey: "file_path")
            return ClaudePermission(tool: tool, project: project, title: rawTool == "Write" ? "Write a file" : "Edit a file",
                                    body: visible(path) + "\n\n" + pretty(rest), detail: nil)
        case "WebFetch":
            return ClaudePermission(tool: tool, project: project, title: "Open a web page", body: pretty(input), detail: nil)
        default:
            return ClaudePermission(tool: tool, project: project, title: "Use \(tool)", body: pretty(input), detail: detail)
        }
    }

    public static func appName(termProgram: String?) -> String? {
        switch termProgram {
        case nil, "": nil
        case "vscode": "VS Code"
        case "Apple_Terminal": "Terminal"
        case "iTerm.app": "iTerm"
        case "ghostty": "Ghostty"
        case "WarpTerminal": "Warp"
        case let other?: other
        }
    }

    static func pretty(_ object: [String: Any]) -> String {
        object.keys.sorted().map { "\($0): \(visible(format(object[$0]!)))" }.joined(separator: "\n")
    }

    /// Any JSON value as text, without throwing (JSONSerialization raises on bare scalars).
    static func format(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        }
        if value is NSNull { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }

    /// Makes every character that could disguise text visible, as ⟨U+XXXX⟩: control and format characters (bidi
    /// overrides, zero-width, tags), default-ignorable code points, line/paragraph separators and any space other
    /// than a plain one. Newline and tab are kept.
    public static func visible(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let hidden: Bool
            if v == 0x0A || v == 0x09 || v == 0x20 {
                hidden = false
            } else {
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .privateUse, .surrogate, .unassigned:
                    hidden = true
                default:
                    hidden = scalar.properties.isDefaultIgnorableCodePoint
                }
            }
            if hidden { out += String(format: "⟨U+%04X⟩", v) } else { out.unicodeScalars.append(scalar) }
        }
        return out
    }
}
