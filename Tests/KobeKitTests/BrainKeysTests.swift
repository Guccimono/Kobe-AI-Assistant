import Testing
@testable import KobeKit

struct BrainKeysTests {
    @Test func roundTrip() {
        let store = InMemorySecrets()
        let keys = BrainKeys(store: store)
        #expect(keys.load(.claude) == nil)
        #expect(keys.save("  sk-ant-abc \n", for: .claude))
        #expect(keys.load(.claude) == "sk-ant-abc")
        #expect(store.read(service: Brand.servicesKeychain, account: "brain-claude") != nil)
        #expect(keys.save("sk-ant-new", for: .claude))
        #expect(keys.load(.claude) == "sk-ant-new")
        #expect(keys.load(.openai) == nil)
        keys.delete(for: .claude)
        #expect(keys.load(.claude) == nil)
        #expect(keys.save("  ", for: .openai) == false)
        #expect(keys.save("x", for: .ollama) == false)
    }

    @Test func innerWhitespaceIsRefused() {
        let store = InMemorySecrets()
        let keys = BrainKeys(store: store)
        #expect(keys.save("sk-ant-abc def", for: .claude) == false)
        #expect(keys.save("sk-ant-abc\nsk-ant-def", for: .claude) == false)
        #expect(store.read(service: Brand.servicesKeychain, account: "brain-claude") == nil)
    }
}
