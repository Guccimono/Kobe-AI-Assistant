import Foundation

/// One Hermes session (a chat), as `GET /api/sessions` returns it.
public struct HermesSession: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let source: String?
    public let model: String?
    public let title: String?
    public let lastActive: Double?
    public let preview: String?
    public let messageCount: Int?
    public let startedAt: Double?
    public let toolCallCount: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// Usage Hermes keeps per chat: cached input read and written, reasoning, model calls, and the cost in US
    /// dollars (its estimate, and what the provider charged when it says).
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let reasoningTokens: Int?
    public let apiCallCount: Int?
    public let estimatedCostUsd: Double?
    public let actualCostUsd: Double?
    /// Whether the session carries a system prompt (`has_system_prompt`); nil when the engine doesn't say.
    public let hasSystemPrompt: Bool?

    public init(id: String, source: String?, model: String?, title: String?, lastActive: Double?, preview: String?, messageCount: Int?,
                startedAt: Double? = nil, toolCallCount: Int? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
                cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil, reasoningTokens: Int? = nil,
                apiCallCount: Int? = nil, estimatedCostUsd: Double? = nil, actualCostUsd: Double? = nil,
                hasSystemPrompt: Bool? = nil) {
        self.id = id
        self.source = source
        self.model = model
        self.title = title
        self.lastActive = lastActive
        self.preview = preview
        self.messageCount = messageCount
        self.startedAt = startedAt
        self.toolCallCount = toolCallCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.apiCallCount = apiCallCount
        self.estimatedCostUsd = estimatedCostUsd
        self.actualCostUsd = actualCostUsd
        self.hasSystemPrompt = hasSystemPrompt
    }

    /// What the chat cost: the provider's charge when known, else Hermes' estimate; nil when Hermes has neither.
    public var costUsd: Double? { actualCostUsd ?? estimatedCostUsd }

    /// Where the chat came from, for the small chip in lists.
    public var sourceLabel: String { sourceLabel(copy: Copy(name: "Kobe")) }

    /// `sourceLabel`, with the assistant's name for a chat that has no source.
    public func sourceLabel(copy: Copy) -> String {
        if title == ChatTitles.quickAsk { return "Quick ask" }
        switch source ?? "" {
        case "api_server": return "Notch"
        case "whatsapp": return "WhatsApp"
        case "cli", "tui": return "CLI"
        case "": return copy.name
        case let other: return other.prefix(1).uppercased() + other.dropFirst()
        }
    }

    /// Hermes only lets the API add to chats it owns: a WhatsApp or CLI chat can be read here, not continued.
    public var acceptsMessagesFromNotch: Bool {
        switch source {
        case nil, "api_server", "bot_room": true
        default: false
        }
    }

    /// What lists show as the chat's name.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let preview, !preview.isEmpty { return String(preview.prefix(60)) }
        return "New chat"
    }
}

public enum ChatTitles {
    public static let quickAsk = "Quick ask"
}

/// One message in a session. Hermes stores ids as integers; content may be a string or a list of parts.
public struct HermesMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let content: String
    public let timestamp: Double?

    public init(id: String, role: String, content: String, timestamp: Double?) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

public struct HermesHealth: Equatable, Sendable {
    public let reachable: Bool
    public let version: String?
    /// Platform name → connected.
    public let platforms: [String: Bool]

    public init(reachable: Bool, version: String?, platforms: [String: Bool]) {
        self.reachable = reachable
        self.version = version
        self.platforms = platforms
    }
}

public enum HermesError: Error, Equatable, Sendable {
    case noKey
    case unauthorized
    case notFound(String)
    case offline
    case server(status: Int, code: String?, message: String)
}

/// The only approval answers the app sends: one-time yes, or no. Never "session" or "always".
public enum ApprovalChoice: String, Sendable {
    case once, deny
}

// MARK: - Wire decoding

struct SessionListWire: Decodable {
    let data: [HermesSession]
}

struct SessionWire: Decodable {
    let session: HermesSession
}

struct MessageListWire: Decodable {
    let data: [MessageWire]
}

struct MessageWire: Decodable {
    let id: String
    let role: String
    let content: String
    let timestamp: Double?
    let displayKind: String?

    enum CodingKeys: String, CodingKey { case id, role, content, timestamp, displayKind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? c.decode(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        role = try c.decode(String.self, forKey: .role)
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp)
        displayKind = try c.decodeIfPresent(String.self, forKey: .displayKind)
        if let text = try? c.decode(String.self, forKey: .content) {
            content = text
        } else if let parts = try? c.decode([ContentPart].self, forKey: .content) {
            content = parts.compactMap(\.text).joined(separator: "\n")
        } else {
            content = ""
        }
    }

    struct ContentPart: Decodable {
        let text: String?
    }
}

struct HealthWire: Decodable {
    let version: String?
    let platforms: [String: PlatformWire]?

    struct PlatformWire: Decodable {
        let state: String?
    }
}

struct ErrorWire: Decodable {
    let error: Body

    struct Body: Decodable {
        let message: String?
        let code: String?
    }
}
