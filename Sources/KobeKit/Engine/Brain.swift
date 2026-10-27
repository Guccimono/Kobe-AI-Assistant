import Foundation

/// The four model providers on the onboarding's "Pick a brain" screen. Pure data: copy, where to check a key,
/// and what to write into the engine. No I/O.
public enum Brain: String, CaseIterable, Codable, Sendable {
    case claude, openai, openrouter, ollama

    /// Placeholder for Task 11's builder to adjust against Hermes's Providers page.
    public static let ollamaModel = "qwen3:8b"

    public var label: String {
        switch self {
        case .claude: "Claude"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .ollama: "On this Mac (Ollama)"
        }
    }

    /// The provider's name in a sentence ("Anthropic doesn't recognise this key").
    public var maker: String {
        switch self {
        case .claude: "Anthropic"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama"
        }
    }

    public var blurb: String {
        switch self {
        case .claude: "By Anthropic. Best at understanding what you mean."
        case .openai: "GPT models. Solid all-rounder."
        case .openrouter: "One key, many models, switch any time."
        case .ollama: "Free and private. Slower, less sharp, needs a 5 GB download and a recent Mac."
        }
    }

    public var cost: String {
        switch self {
        case .claude: "About the price of a coffee for a day of chatting."
        case .openai: "Pay per use, similar."
        case .openrouter: "Pay per use."
        case .ollama: "Free."
        }
    }

    /// "a" or "an" for the label in a sentence.
    public var article: String { self == .claude ? "a" : "an" }

    public var recommended: Bool { self == .claude }
    public var needsKey: Bool { self != .ollama }

    /// What goes into `~/.hermes/.env`. A nil value is the pasted key.
    /// Names are the conventional ones; only OPENROUTER_API_KEY is confirmed against the Hermes docs.
    public var envWrites: [(key: String, value: String?)] {
        switch self {
        case .claude: [("ANTHROPIC_API_KEY", nil)]
        case .openai: [("OPENAI_API_KEY", nil)]
        case .openrouter: [("OPENROUTER_API_KEY", nil)]
        case .ollama: [("OPENAI_BASE_URL", "http://127.0.0.1:11434/v1"), ("OPENAI_API_KEY", "ollama")]
        }
    }

    /// The non-secret `hermes config set` pairs (provider, model).
    /// Placeholders: the builder of the connect step may adjust them against Hermes's Providers page.
    public var modelConfig: [(key: String, value: String)] {
        switch self {
        case .claude: [("provider", "anthropic"), ("model", "claude-sonnet-4-5")]
        case .openai: [("provider", "openai"), ("model", "gpt-5")]
        case .openrouter: [("provider", "openrouter"), ("model", "anthropic/claude-sonnet-4-5")]
        case .ollama: [("provider", "custom"), ("model", Brain.ollamaModel)]
        }
    }

    /// The models endpoint a key is checked against.
    public var checkURL: URL {
        switch self {
        case .claude: URL(string: "https://api.anthropic.com/v1/models")!
        case .openai: URL(string: "https://api.openai.com/v1/models")!
        case .openrouter: URL(string: "https://openrouter.ai/api/v1/models")!
        case .ollama: URL(string: "http://127.0.0.1:11434/api/tags")!
        }
    }

    /// Where to create a key (Ollama: where to download it).
    public var createKeyURL: URL? {
        switch self {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .ollama: URL(string: "https://ollama.com/download")
        }
    }

    public var placeholder: String {
        switch self {
        case .claude: "sk-ant-…  (paste it here)"
        case .openai: "sk-…  (paste it here)"
        case .openrouter: "sk-or-…  (paste it here)"
        case .ollama: "No key needed"
        }
    }

    /// Plain-text help line; the link is `createKeyURL`.
    public var help: String {
        switch self {
        case .claude: "An API key is a long password that lets the engine use the model on your behalf. Create one at Anthropic (free account, add a few dollars), copy it, paste it above."
        case .openai: "Create a key at OpenAI, add a few dollars of credit, paste it above."
        case .openrouter: "Create a key at OpenRouter; one key gives you Claude, GPT and open models."
        case .ollama: "Kobe looks for Ollama on this Mac. Not here yet? Install Ollama, then Kobe fetches the recommended model (5 GB)."
        }
    }

    public func authHeaders(key: String) -> [(name: String, value: String)] {
        switch self {
        case .claude: [("x-api-key", key), ("anthropic-version", "2023-06-01")]
        case .openai, .openrouter: [("Authorization", "Bearer " + key)]
        case .ollama: []
        }
    }
}
