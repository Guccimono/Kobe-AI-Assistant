import Foundation
import Testing
@testable import KobeKit

private let day: Double = 86_400
private let now = Date(timeIntervalSince1970: 1_792_600_000)

private func session(_ id: String, daysAgo: Double, source: String, messages: Int, tools: Int = 0, tokens: (Int, Int) = (0, 0)) -> HermesSession {
    HermesSession(id: id, source: source, model: nil, title: nil, lastActive: nil, preview: nil, messageCount: messages,
                  startedAt: now.timeIntervalSince1970 - daysAgo * day, toolCallCount: tools, inputTokens: tokens.0, outputTokens: tokens.1)
}

@Test func totalsForTheWeek() {
    let sessions = [
        session("a", daysAgo: 1, source: "api_server", messages: 6, tools: 2, tokens: (1000, 500)),
        session("b", daysAgo: 3, source: "whatsapp", messages: 4, tools: 1, tokens: (200, 100)),
        session("c", daysAgo: 20, source: "api_server", messages: 10),
    ]
    let stats = Statistics.compute(sessions: sessions, period: .week, now: now)
    #expect(stats.chats == 2)
    #expect(stats.messages == 10)
    #expect(stats.toolCalls == 3)
    #expect(stats.tokens == 1800)
}

@Test func perDayHasOneBarPerDayOfThePeriod() {
    let stats = Statistics.compute(sessions: [session("a", daysAgo: 0, source: "api_server", messages: 5)], period: .month, now: now)
    #expect(stats.perDay.count == 30)
    #expect(stats.perDay.last?.messages == 5)
    #expect(stats.perDay.dropLast().allSatisfy { $0.messages == 0 })
}

@Test func whereYouTalkIsSharedBySource() {
    let sessions = [
        session("a", daysAgo: 1, source: "api_server", messages: 3),
        session("b", daysAgo: 1, source: "whatsapp", messages: 1),
    ]
    let stats = Statistics.compute(sessions: sessions, period: .week, now: now)
    #expect(stats.bySource.map(\.label) == ["Notch", "WhatsApp"])
    #expect(stats.bySource.map(\.share) == [0.75, 0.25])
}

@Test func allTimeCountsEverything() {
    let sessions = [session("a", daysAgo: 1, source: "cli", messages: 2), session("b", daysAgo: 400, source: "cli", messages: 3)]
    let stats = Statistics.compute(sessions: sessions, period: .all, now: now)
    #expect(stats.messages == 5)
    #expect(stats.perDay.count == 90)  // the chart shows the last 90 days
}

// MARK: Models and cost

private func used(_ id: String, model: String?, tokens: (Int, Int), cache: Int = 0, estimated: Double? = nil,
                  actual: Double? = nil, daysAgo: Double = 1) -> HermesSession {
    HermesSession(id: id, source: "api_server", model: model, title: nil, lastActive: nil, preview: nil, messageCount: 2,
                  startedAt: now.timeIntervalSince1970 - daysAgo * day, toolCallCount: 0, inputTokens: tokens.0,
                  outputTokens: tokens.1, cacheReadTokens: cache, estimatedCostUsd: estimated, actualCostUsd: actual)
}

@Test func decodesHermesUsageFields() throws {
    let json = #"{"id":"s","model":"anthropic/claude-sonnet-5.5","input_tokens":10,"output_tokens":2,"cache_read_tokens":30,"cache_write_tokens":4,"reasoning_tokens":5,"estimated_cost_usd":0.12,"actual_cost_usd":null,"api_call_count":3}"#
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let s = try decoder.decode(HermesSession.self, from: Data(json.utf8))
    #expect(s.cacheReadTokens == 30 && s.cacheWriteTokens == 4 && s.reasoningTokens == 5)
    #expect(s.estimatedCostUsd == 0.12 && s.actualCostUsd == nil && s.apiCallCount == 3)
}

@Test func costPrefersWhatTheProviderCharged() {
    let stats = Statistics.compute(sessions: [
        used("a", model: "anthropic/claude-sonnet-5.5", tokens: (1000, 100), estimated: 0.50, actual: 0.42),
        used("b", model: "anthropic/claude-sonnet-5.5", tokens: (1000, 100), estimated: 0.30),
        used("c", model: "mystery", tokens: (500, 50)),
    ], period: .week, now: now)
    #expect(abs(stats.costUsd - 0.72) < 0.0001)
    // A chat Hermes couldn't price is counted, not guessed.
    #expect(stats.unpricedChats == 1)
}

@Test func usageByModelWithItsPlace() {
    let stats = Statistics.compute(sessions: [
        used("a", model: "nvidia/nemotron-3-ultra-550b-a55b:free", tokens: (300, 10), cache: 500, estimated: 0),
        used("b", model: "anthropic/claude-sonnet-5.5", tokens: (100, 20), estimated: 0.20),
        used("c", model: "anthropic/claude-sonnet-5.5", tokens: (100, 20), estimated: 0.10),
        used("d", model: "ollama/qwen3:32b", tokens: (50, 5)),
        used("e", model: nil, tokens: (1, 1)),
    ], period: .week, now: now)
    #expect(stats.byModel.map(\.model) == ["anthropic/claude-sonnet-5.5", "nvidia/nemotron-3-ultra-550b-a55b:free",
                                           "ollama/qwen3:32b", "Unknown"])
    let sonnet = stats.byModel[0]
    #expect(sonnet.chats == 2 && sonnet.tokens == 240 && abs(sonnet.costUsd - 0.30) < 0.0001 && sonnet.place == .cloud)
    #expect(stats.byModel[1].place == .free && stats.byModel[1].cachedTokens == 500)
    #expect(stats.byModel[2].place == .local)
    #expect(stats.cachedTokens == 500)
}

@Test func cloudFreeAndLocalShares() {
    let stats = Statistics.compute(sessions: [
        used("a", model: "openai/gpt-5.5", tokens: (500, 0), estimated: 1),
        used("b", model: "meta/llama:free", tokens: (300, 0), estimated: 0),
        used("c", model: "lmstudio/gemma-4", tokens: (200, 0)),
    ], period: .week, now: now)
    #expect(stats.byPlace.map(\.label) == ["Cloud", "Cloud (free)", "Local"])
    #expect(stats.byPlace.map(\.share) == [0.5, 0.3, 0.2])
}

@Test func whereAModelRuns() {
    #expect(ModelPlace.of("ollama/qwen3:32b") == .local)
    #expect(ModelPlace.of("LM-Studio/gemma") == .local)
    #expect(ModelPlace.of("mlx-community/Qwen3-8B") == .local)
    #expect(ModelPlace.of("http://localhost:11434/llama3") == .local)
    #expect(ModelPlace.of("meta-llama/llama-4:free") == .free)
    #expect(ModelPlace.of("anthropic/claude-opus-5.5") == .cloud)
    #expect(ModelPlace.of(nil) == .cloud)
}

@Test func costReadsLikeMoney() {
    #expect(Statistics.dollars(0) == "$0")
    #expect(Statistics.dollars(0.004) == "<$0.01")
    #expect(Statistics.dollars(0.72) == "$0.72")
    #expect(Statistics.dollars(12.4) == "$12.40")
    #expect(Statistics.dollars(1234.5) == "$1,235")
}
