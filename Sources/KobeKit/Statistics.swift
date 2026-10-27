import Foundation

/// Where a model runs, read from its name: on this Mac (Ollama, LM Studio, MLX, llama.cpp, a localhost URL), a free
/// cloud model (`:free`), or a paid cloud one.
public enum ModelPlace: Int, Comparable, Sendable {
    case cloud, free, local

    public var label: String {
        switch self {
        case .cloud: "Cloud"
        case .free: "Cloud (free)"
        case .local: "Local"
        }
    }

    static let localProviders: Set<String> = ["ollama", "lmstudio", "lm-studio", "mlx", "mlx-community", "llama.cpp",
                                              "llamacpp", "local", "gguf"]

    public static func of(_ model: String?) -> ModelPlace {
        guard let model = model?.lowercased() else { return .cloud }
        if model.contains("localhost") || model.contains("127.0.0.1") { return .local }
        if let provider = model.split(separator: "/").first, localProviders.contains(String(provider)) { return .local }
        return model.hasSuffix(":free") ? .free : .cloud
    }

    public static func < (a: ModelPlace, b: ModelPlace) -> Bool { a.rawValue < b.rawValue }
}

/// Usage numbers for the Statistics page, computed on this Mac from Hermes' session list. Nothing is sent anywhere.
public struct Statistics: Equatable, Sendable {
    public enum Period: String, CaseIterable, Sendable { case week = "Week", month = "Month", all = "All" }

    public struct Day: Equatable, Sendable {
        public let start: Date
        public let messages: Int
    }

    public struct Share: Equatable, Sendable {
        public let label: String
        public let share: Double
    }

    /// One model's share of the period.
    public struct ModelUsage: Equatable, Sendable {
        public let model: String
        public let place: ModelPlace
        public let chats: Int
        /// In and out.
        public let tokens: Int
        public let cachedTokens: Int
        public let costUsd: Double
    }

    public var chats = 0
    public var messages = 0
    public var toolCalls = 0
    public var tokens = 0
    /// One bar per day: 7 for a week, 30 for a month, the last 90 days for all time.
    public var perDay: [Day] = []
    /// Where you talk to Kobe (Notch, WhatsApp, CLI …), by share of messages, largest first.
    public var bySource: [Share] = []
    /// Hermes' cost for the period (the provider's charge when known, else its estimate), in US dollars.
    public var costUsd = 0.0
    /// Chats Hermes couldn't price: counted, never guessed.
    public var unpricedChats = 0
    /// Cached input read on top of `tokens` (cheaper, so kept apart).
    public var cachedTokens = 0
    /// Most expensive first, then most tokens.
    public var byModel: [ModelUsage] = []
    /// Cloud, free cloud and local, by share of tokens, largest first.
    public var byPlace: [Share] = []

    /// "$0", "<$0.01", "$0.72", "$12.40", "$1,235" (whole dollars from 1,000).
    public static func dollars(_ amount: Double) -> String {
        if amount <= 0 { return "$0" }
        if amount < 0.01 { return "<$0.01" }
        let style = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "en_US"))
        return "$" + (amount >= 1000 ? amount.rounded().formatted(style.precision(.fractionLength(0)))
                                     : amount.formatted(style.precision(.fractionLength(2)).grouping(.never)))
    }

    /// A chat counts on the day it started.
    public static func compute(sessions: [HermesSession], period: Period, now: Date = Date(), calendar: Calendar = .current,
                                copy: Copy = Copy(name: "Kobe")) -> Statistics {
        let days = switch period {
        case .week: 7
        case .month: 30
        case .all: 90
        }
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        let inPeriod = sessions.filter { session in
            guard period != .all else { return true }
            let started = Date(timeIntervalSince1970: session.startedAt ?? session.lastActive ?? 0)
            return started >= first
        }
        var stats = Statistics()
        stats.chats = inPeriod.count
        stats.messages = inPeriod.reduce(0) { $0 + ($1.messageCount ?? 0) }
        stats.toolCalls = inPeriod.reduce(0) { $0 + ($1.toolCallCount ?? 0) }
        stats.tokens = inPeriod.reduce(0) { $0 + ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) }

        var buckets = Array(repeating: 0, count: days)
        for session in inPeriod {
            let started = calendar.startOfDay(for: Date(timeIntervalSince1970: session.startedAt ?? session.lastActive ?? 0))
            if let offset = calendar.dateComponents([.day], from: first, to: started).day, (0..<days).contains(offset) {
                buckets[offset] += session.messageCount ?? 0
            }
        }
        stats.perDay = buckets.enumerated().map { Day(start: calendar.date(byAdding: .day, value: $0.offset, to: first)!, messages: $0.element) }

        var bySource: [String: Int] = [:]
        for session in inPeriod { bySource[session.sourceLabel(copy: copy), default: 0] += session.messageCount ?? 0 }
        let total = max(1, bySource.values.reduce(0, +))
        stats.bySource = bySource.map { Share(label: $0.key, share: Double($0.value) / Double(total)) }
            .filter { $0.share > 0 }
            .sorted { $0.share == $1.share ? $0.label < $1.label : $0.share > $1.share }

        stats.costUsd = inPeriod.reduce(0) { $0 + ($1.costUsd ?? 0) }
        stats.unpricedChats = inPeriod.filter { $0.costUsd == nil }.count
        stats.cachedTokens = inPeriod.reduce(0) { $0 + ($1.cacheReadTokens ?? 0) }
        let grouped = Dictionary(grouping: inPeriod) { $0.model ?? "" }
        stats.byModel = grouped.map { model, list in
            ModelUsage(model: model.isEmpty ? "Unknown" : model, place: ModelPlace.of(model.isEmpty ? nil : model),
                       chats: list.count, tokens: list.reduce(0) { $0 + ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) },
                       cachedTokens: list.reduce(0) { $0 + ($1.cacheReadTokens ?? 0) },
                       costUsd: list.reduce(0) { $0 + ($1.costUsd ?? 0) })
        }.sorted { a, b in
            if a.costUsd != b.costUsd { return a.costUsd > b.costUsd }
            if a.tokens != b.tokens { return a.tokens > b.tokens }
            return a.model < b.model
        }
        var placeTokens: [ModelPlace: Int] = [:]
        for usage in stats.byModel { placeTokens[usage.place, default: 0] += usage.tokens }
        let allTokens = max(1, placeTokens.values.reduce(0, +))
        stats.byPlace = placeTokens.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { Share(label: $0.key.label, share: Double($0.value) / Double(allTokens)) }
        return stats
    }
}
