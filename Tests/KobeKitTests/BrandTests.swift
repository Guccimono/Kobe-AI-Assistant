import Testing
@testable import KobeKit

@Suite struct BrandTests {
    @Test func identifiersShareOnePrefix() {
        #expect(Brand.bundleID == "com.kobe-assistant.app")
        #expect(Brand.hookBundleID.hasPrefix(Brand.bundleID))
        #expect(ServiceKeys.service == Brand.servicesKeychain)
        #expect(HermesKey.service == Brand.engineKeychain)
        #expect(!Brand.servicesKeychain.contains("notch"))
    }
}
