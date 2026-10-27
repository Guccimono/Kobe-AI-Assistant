import Foundation
import Testing
@testable import KobeKit

@Suite struct KeyCheckTests {
    @Test func trimsPastedKey() {
        #expect(KeyCheck.trimmed("  sk-ant-x\n") == "sk-ant-x")
        #expect(KeyCheck.trimmed(" sk-a b\n") == "sk-a b")
    }

    @Test func sniffsPrefixes() {
        #expect(KeyCheck.sniff("sk-ant-api03-abc") == .claude)
        #expect(KeyCheck.sniff("sk-or-v1-abc") == .openrouter)
        #expect(KeyCheck.sniff("sk-proj-abc") == .openai)
        #expect(KeyCheck.sniff("sk-abc") == .openai)
        #expect(KeyCheck.sniff("hello") == nil)
        #expect(KeyCheck.sniff("") == nil)
    }

    @Test func wrongProviderBeforeRefused() {
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-abc", status: 401, modelCount: nil) == .wrongProvider(looksLike: .openai))
        #expect(KeyCheck.verdict(brain: .openai, key: "sk-ant-abc", status: 401, modelCount: nil) == .wrongProvider(looksLike: .claude))
    }

    @Test func worksCountsModels() {
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-ant-x", status: 200, modelCount: 12) == .works(models: 12))
        #expect(KeyCheck.verdict(brain: .openai, key: "sk-proj-x", status: 200, modelCount: nil) == .works(models: 0))
    }

    @Test func refusedWhenPrefixFitsOrIsUnknown() {
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-ant-x", status: 401, modelCount: nil) == .refused(by: .claude))
        #expect(KeyCheck.verdict(brain: .claude, key: "nonsense", status: 403, modelCount: nil) == .refused(by: .claude))
    }

    @Test func nilStatusIsUnreachable() {
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-ant-x", status: nil, modelCount: nil) == .unreachable)
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-abc", status: nil, modelCount: nil) == .unreachable)
    }

    @Test func ollamaNeedsNoKey() {
        #expect(Brain.ollama.needsKey == false)
        #expect(Brain.claude.needsKey && Brain.openai.needsKey && Brain.openrouter.needsKey)
        #expect(KeyCheck.verdict(brain: .ollama, key: "", status: 200, modelCount: 3) == .works(models: 3))
        #expect(Brain.ollama.authHeaders(key: "x").isEmpty)
        #expect(Brain.ollama.checkURL.absoluteString == "http://127.0.0.1:11434/api/tags")
        let writes = Brain.ollama.envWrites
        #expect(writes.count == 2)
        #expect(writes[0].key == "OPENAI_BASE_URL" && writes[0].value == "http://127.0.0.1:11434/v1")
        #expect(writes[1].key == "OPENAI_API_KEY" && writes[1].value == "ollama")
        #expect(Brain.ollamaModel == "qwen3:8b")
    }

    @Test func everyDoorHasCopy() {
        for b in Brain.allCases {
            #expect(!b.label.isEmpty && !b.blurb.isEmpty && !b.cost.isEmpty)
            #expect(!b.placeholder.isEmpty && !b.help.isEmpty)
            #expect(b.createKeyURL != nil)
            #expect(!b.modelConfig.isEmpty)
            #expect(b.recommended == (b == .claude))
        }
        #expect(Brain.claude.envWrites.map(\.key) == ["ANTHROPIC_API_KEY"])
        #expect(Brain.claude.envWrites[0].value == nil)
        #expect(Brain.openrouter.envWrites.map(\.key) == ["OPENROUTER_API_KEY"])
    }

    @Test func authHeaders() {
        let c = Brain.claude.authHeaders(key: "k")
        #expect(c.count == 2)
        #expect(c[0].name == "x-api-key" && c[0].value == "k")
        #expect(c[1].name == "anthropic-version" && c[1].value == "2023-06-01")
        let o = Brain.openai.authHeaders(key: "k")
        #expect(o.count == 1 && o[0].name == "Authorization" && o[0].value == "Bearer k")
    }

    @Test func linesMatchTheMock() {
        let w = KeyCheck.line(.works(models: 12), brain: .claude)
        #expect(w.text == "Key works. 12 models available." && w.tone == .ok)
        let p = KeyCheck.line(.wrongProvider(looksLike: .openai), brain: .claude)
        #expect(p.text == "This looks like an OpenAI key, not a Claude one. Pick OpenAI above, or create a Claude key." && p.tone == .needsYou)
        let r = KeyCheck.line(.refused(by: .claude), brain: .claude)
        #expect(r.text == "Anthropic doesn't recognise this key. Check you copied the whole thing." && r.tone == .failed)
        let u = KeyCheck.line(.unreachable, brain: .openrouter)
        #expect(u.text == "Can't reach OpenRouter right now. You can continue and check later." && u.tone == .neutral)
    }

    @Test func wrongProviderArticles() {
        func text(_ b: Brain, _ k: String) -> String {
            KeyCheck.line(KeyCheck.verdict(brain: b, key: k, status: 401, modelCount: nil), brain: b).text
        }
        #expect(text(.openai, "sk-ant-x") == "This looks like a Claude key, not an OpenAI one. Pick Claude above, or create an OpenAI key.")
        #expect(text(.openai, "sk-or-x") == "This looks like an OpenRouter key, not an OpenAI one. Pick OpenRouter above, or create an OpenAI key.")
        #expect(text(.openrouter, "sk-x") == "This looks like an OpenAI key, not an OpenRouter one. Pick OpenAI above, or create an OpenRouter key.")
    }

    @Test func onlyAuthStatusesAreRefused() {
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-ant-x", status: 429, modelCount: nil) == .unreachable)
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-ant-x", status: 503, modelCount: nil) == .unreachable)
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-abc", status: 503, modelCount: nil) == .unreachable)
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-ant-x", status: 403, modelCount: nil) == .refused(by: .claude))
        #expect(KeyCheck.verdict(brain: .claude, key: "sk-abc", status: 403, modelCount: nil) == .wrongProvider(looksLike: .openai))
    }
}
