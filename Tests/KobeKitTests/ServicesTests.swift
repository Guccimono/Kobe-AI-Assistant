import Foundation
import Testing
@testable import KobeKit

@Test func serviceKeysLiveInTheirOwnKeychainService() {
    let keys = ServiceKeys(store: InMemorySecrets())
    #expect(!keys.isSet(.github))
    #expect(keys.save("  ghp  ", for: .github))
    #expect(keys.load(.github) == "ghp")
    keys.remove(.github)
    #expect(!keys.isSet(.github))
    #expect(ServiceKeys.service == Brand.servicesKeychain)
}

@Test func stripeRefusesFullSecretKeys() {
    let keys = ServiceKeys(store: InMemorySecrets())
    #expect(!keys.save("sk_live_123", for: .stripe))
    #expect(keys.save("rk_live_123", for: .stripe))
}

@Test func aFailedServiceKeyReadIsRetried() {
    let store = FlakySecrets()
    _ = store.write(service: ServiceKeys.service, account: "github", data: Data("ghp".utf8))
    store.failures = 1
    let keys = ServiceKeys(store: store)
    #expect(keys.load(.github) == nil)
    #expect(keys.load(.github) == "ghp")
    #expect(store.reads == 2)
    #expect(keys.load(.github) == "ghp")
    #expect(store.reads == 2)  // a successful read is kept
}
