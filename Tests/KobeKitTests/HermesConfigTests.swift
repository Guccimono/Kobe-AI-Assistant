import Foundation
import Testing
@testable import KobeKit

@Suite struct HermesConfigTests {
    @Test func insertsBlockIntoEmptyFile() {
        let out = HermesConfig.mergeApiServer(into: "", host: "127.0.0.1", port: 8642, key: "k1")!
        #expect(out == "gateway:\n  api_server:\n    enabled: true\n    host: 127.0.0.1\n    port: 8642\n    key: k1\n")
        let api = HermesConfig.apiServer(in: out)
        #expect(api?.enabled == true && api?.host == "127.0.0.1" && api?.port == 8642 && api?.hasKey == true)
    }

    @Test func mergeKeepsUnknownKeys() {
        let yaml = "# my config\nmodel:\n  default: x\n\ngateway:\n  platforms:\n    telegram: {token: t}\n# tail\nagent:\n  a: 1\n"
        let out = HermesConfig.mergeApiServer(into: yaml, host: "127.0.0.1", port: 8642, key: "k")!
        let expected = "# my config\nmodel:\n  default: x\n\ngateway:\n  platforms:\n    telegram: {token: t}\n  api_server:\n    enabled: true\n    host: 127.0.0.1\n    port: 8642\n    key: k\n# tail\nagent:\n  a: 1\n"
        #expect(out == expected)
    }

    @Test func appendsGatewayWhenAbsent() {
        let out = HermesConfig.mergeApiServer(into: "model: x", host: "h", port: 1, key: "k")!
        #expect(out == "model: x\ngateway:\n  api_server:\n    enabled: true\n    host: h\n    port: 1\n    key: k\n")
    }

    @Test func replacesExistingKey() {
        let yaml = "gateway:\n  api_server:\n    enabled: false\n    host: 0.0.0.0\n    port: 1\n    key: \"old\"\n    cors: yes\nx: 1\n"
        let out = HermesConfig.mergeApiServer(into: yaml, host: "127.0.0.1", port: 8642, key: "new")!
        #expect(out == "gateway:\n  api_server:\n    enabled: true\n    host: 127.0.0.1\n    port: 8642\n    key: new\n    cors: yes\nx: 1\n")
        #expect(out.components(separatedBy: "api_server:").count == 2)
    }

    @Test func editsPlatformsVariantsInPlace() {
        let a = "gateway:\n  platforms:\n    api_server:\n      key: old\n"
        let outA = HermesConfig.mergeApiServer(into: a, host: "127.0.0.1", port: 8642, key: "n")!
        #expect(outA == "gateway:\n  platforms:\n    api_server:\n      key: n\n      enabled: true\n      host: 127.0.0.1\n      port: 8642\n")
        let b = "platforms:\n  api_server:\n    enabled: true\n"
        #expect(HermesConfig.apiServer(in: b)?.hasKey == false)
        #expect(HermesConfig.mergeApiServer(into: b, host: "h", port: 2, key: "n")!.hasPrefix("platforms:\n  api_server:\n    enabled: true\n    host: h"))
        #expect(!HermesConfig.mergeApiServer(into: b, host: "h", port: 2, key: "n")!.contains("gateway"))
    }

    @Test func nilKeyKeepsTheBlocksOwnKey() throws {
        let yaml = "gateway:\n  api_server:\n    enabled: false\n    port: 1\n    key: old\n"
        let out = try #require(HermesConfig.mergeApiServer(into: yaml, host: "127.0.0.1", port: 8642, key: nil))
        #expect(out == "gateway:\n  api_server:\n    enabled: true\n    port: 8642\n    key: old\n    host: 127.0.0.1\n")
    }

    @Test func fourSpaceFileKeepsItsUnit() throws {
        let out = try #require(HermesConfig.mergeApiServer(into: "gateway:\n    platforms:\n        x: 1\n", host: "h", port: 1, key: "k"))
        #expect(out == "gateway:\n    platforms:\n        x: 1\n    api_server:\n        enabled: true\n        host: h\n        port: 1\n        key: k\n")
        #expect(HermesConfig.apiServer(in: out)?.port == 1)
    }

    @Test func emptyGatewayUsesTwoSpaces() throws {
        let out = try #require(HermesConfig.mergeApiServer(into: "gateway:\nx: 1\n", host: "h", port: 1, key: "k"))
        #expect(out == "gateway:\n  api_server:\n    enabled: true\n    host: h\n    port: 1\n    key: k\nx: 1\n")
    }

    @Test func inlineValuesAreRefused() {
        #expect(HermesConfig.mergeApiServer(into: "gateway: {}\n", host: "h", port: 1, key: "k") == nil)
        #expect(HermesConfig.mergeApiServer(into: "gateway: null\n", host: "h", port: 1, key: "k") == nil)
        #expect(HermesConfig.mergeApiServer(into: "gateway:\n  api_server: {}\n", host: "h", port: 1, key: "k") == nil)
        #expect(HermesConfig.mergeApiServer(into: "platforms:\n  api_server: {}\n", host: "h", port: 1, key: "k") == nil)
        #expect(HermesConfig.mergeApiServer(into: "gateway: # c\n", host: "h", port: 1, key: "k") != nil)
    }

    @Test func crlfFilesStayCrlf() throws {
        let yaml = "gateway:\r\n  platforms:\r\n    t: 1\r\nx: 1\r\n"
        let out = try #require(HermesConfig.mergeApiServer(into: yaml, host: "h", port: 1, key: "k"))
        #expect(out == "gateway:\r\n  platforms:\r\n    t: 1\r\n  api_server:\r\n    enabled: true\r\n    host: h\r\n    port: 1\r\n    key: k\r\nx: 1\r\n")
        #expect(HermesConfig.apiServer(in: out)?.hasKey == true)
        #expect(HermesConfig.hasProviderKey(env: "ANTHROPIC_API_KEY=\r\nOPENAI_API_KEY=x\r\n") == .openai)
        #expect(HermesConfig.setEnv("A=1\r\nKEY=x\r\n", key: "KEY", value: "n") == "A=1\r\nKEY=n\r\n")
        #expect(HermesConfig.setEnv("A=1\r\n", key: "KEY", value: "n") == "A=1\r\nKEY=n\r\n")
    }

    @Test func readsApiServer() {
        #expect(HermesConfig.apiServer(in: "model: x\n") == nil)
        let q = "gateway:\n  api_server:\n    enabled: true # on\n    host: '127.0.0.1'\n    port: 8642\n    key: 'abc'\n"
        let r = HermesConfig.apiServer(in: q)
        #expect(r?.enabled == true && r?.host == "127.0.0.1" && r?.port == 8642 && r?.hasKey == true)
        let e = HermesConfig.apiServer(in: "gateway:\n  api_server:\n    key: \"\"\n")
        #expect(e?.hasKey == false && e?.enabled == false)
        let nested = HermesConfig.apiServer(in: "gateway:\n  platforms:\n    api_server:\n      port: 9\n")
        #expect(nested?.port == 9)
    }

    @Test func setEnvReplacesOneLine() {
        let env = "A=1\n# KEY=old\nKEY=x\nB=2\n"
        #expect(HermesConfig.setEnv(env, key: "KEY", value: "new") == "A=1\n# KEY=old\nKEY=new\nB=2\n")
        #expect(HermesConfig.setEnv("A=1\n# KEY=old\n", key: "KEY", value: "n") == "A=1\n# KEY=old\nKEY=n\n")
        #expect(HermesConfig.setEnv("A=1", key: "KEY", value: "n") == "A=1\nKEY=n")
        #expect(HermesConfig.setEnv("", key: "KEY", value: "n") == "KEY=n\n")
    }

    @Test func engineKeyIs43Chars() {
        let k = HermesConfig.newEngineKey()
        #expect(k.count == 43)
        #expect(!k.contains("=") && !k.contains("+") && !k.contains("/"))
        #expect(HermesConfig.newEngineKey() != k)
        let fixed = HermesConfig.newEngineKey(random: { n in Data(repeating: 0xFF, count: n) })
        #expect(fixed.hasPrefix("____") && fixed.count == 43)
    }

    @Test func hasProviderKeyFindsFirst() {
        #expect(HermesConfig.hasProviderKey(env: "ANTHROPIC_API_KEY=sk\nOPENAI_API_KEY=x\n") == .claude)
        #expect(HermesConfig.hasProviderKey(env: "OPENAI_API_KEY=ollama\nOPENAI_BASE_URL=http://localhost:11434/v1\n") == .ollama)
        #expect(HermesConfig.hasProviderKey(env: "OPENAI_API_KEY=x\n") == .openai)
        #expect(HermesConfig.hasProviderKey(env: "OPENROUTER_API_KEY=x\n") == .openrouter)
        #expect(HermesConfig.hasProviderKey(env: "ANTHROPIC_API_KEY=\n# OPENAI_API_KEY=x\nOTHER=1\n") == nil)
        #expect(HermesConfig.hasProviderKey(env: "") == nil)
    }

    @Test func configSetCommandsBuildsArgv() {
        let cmds = HermesConfig.configSetCommands([(key: "model.default", value: "m"), (key: "a", value: "b")])
        #expect(cmds == [["hermes", "config", "set", "model.default", "m"], ["hermes", "config", "set", "a", "b"]])
        #expect(HermesConfig.configSetCommands([]).isEmpty)
    }

    @Test func removeEnvDropsOnlyThatKey() {
        let env = "A=1\n# OPENAI_BASE_URL=x\nOPENAI_BASE_URL=http://127.0.0.1:11434/v1\nB=2\n"
        #expect(HermesConfig.removeEnv(env, key: "OPENAI_BASE_URL") == "A=1\n# OPENAI_BASE_URL=x\nB=2\n")
        #expect(HermesConfig.removeEnv(env, key: "NOPE") == env)
        #expect(HermesConfig.removeEnv("", key: "A") == "")
        #expect(HermesConfig.envValue(env, key: "B") == "2")
    }
}
