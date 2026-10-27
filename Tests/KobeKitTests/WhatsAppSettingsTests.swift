import Foundation
import Testing
@testable import KobeKit

private func fresh(executable: Set<String> = []) -> (WhatsAppSettings, UserDefaults, InMemorySecrets) {
    let defaults = UserDefaults(suiteName: "wa-test-\(UUID().uuidString)")!
    let secrets = InMemorySecrets()
    let folder = URL(fileURLWithPath: "/tmp/kobe-test/GOWA", isDirectory: true)
    let settings = WhatsAppSettings(defaults: defaults, secrets: secrets, folder: folder,
                                    isExecutable: { executable.contains($0) })
    return (settings, defaults, secrets)
}

private func store(_ secrets: InMemorySecrets, _ account: String, _ value: String) {
    _ = secrets.write(service: WhatsAppSettings.service, account: account, data: Data(value.utf8))
}

@Suite struct WhatsAppSettingsTests {
    @Test func defaultsUseKobesPorts() {
        let (settings, _, _) = fresh()
        #expect(!settings.enabled)
        #expect(settings.gateway == .gowa)
        #expect(settings.port == 47841)
        #expect(settings.markReadOnOpen && settings.respectFocus)
        #expect(settings.filters == WAFilters(muteGroups: true, ignored: []))
        #expect(settings.url == "http://127.0.0.1:47840")
        #expect(settings.webhookURL == "http://127.0.0.1:47841/whatsapp")
        #expect(settings.binaryPath == "/tmp/kobe-test/GOWA/gowa")
        #expect(!settings.autoStart && !settings.isInstalled)
        #expect(WhatsAppSettings.service == Brand.servicesKeychain)
    }

    @Test func theFirstKobeLinkCarriesOver() {
        let (settings, defaults, secrets) = fresh(executable: ["/tmp/kobe-test/GOWA/gowa"])
        defaults.set(true, forKey: "whatsappLinkOn")
        store(secrets, "gowa-auth", "kobe:abc123")
        #expect(settings.enabled)
        #expect(settings.autoStart && settings.isInstalled)
        #expect(settings.credential == "kobe:abc123")
        // Copied to the whatsapp-api-key account.
        #expect(secrets.read(service: WhatsAppSettings.service, account: "whatsapp-api-key") == Data("kobe:abc123".utf8))
        // Cleared in Settings: stays cleared.
        settings.setSecret(WhatsAppSettings.credentialKey, nil)
        #expect(settings.credential == nil)
        settings.enabled = false
        settings.autoStart = false
        #expect(!settings.enabled && !settings.autoStart)
    }

    @Test func openwaNeverGetsGOWAsPassword() {
        let (settings, _, secrets) = fresh()
        store(secrets, "gowa-auth", "kobe:abc")
        settings.gateway = .openwa
        #expect(settings.credential == nil)
        #expect(settings.url == "http://127.0.0.1:2785")
    }

    @Test func portAndFiltersRoundTrip() {
        let (settings, _, _) = fresh()
        settings.port = 80
        #expect(settings.port == 47841)
        settings.port = 50000
        #expect(settings.port == 50000)
        settings.filters = WAFilters(muteGroups: false, ignored: ["b@g.us", "a@g.us"])
        #expect(settings.filters == WAFilters(muteGroups: false, ignored: ["a@g.us", "b@g.us"]))
    }

    @Test func secretsAreCachedAndRemovable() {
        let (settings, _, secrets) = fresh()
        settings.setSecret(WhatsAppSettings.urlKey, "  http://127.0.0.1:9000  ")
        #expect(settings.url == "http://127.0.0.1:9000")
        secrets.delete(service: WhatsAppSettings.service, account: WhatsAppSettings.urlKey)
        #expect(settings.url == "http://127.0.0.1:9000")   // read once
        settings.setSecret(WhatsAppSettings.urlKey, "")
        #expect(settings.customURL == nil)
    }

    @Test func webhookSecretIsMadeOnce() {
        let (settings, _, _) = fresh()
        let first = settings.webhookSecret()
        #expect(first.count == 64 && first.allSatisfy(\.isHexDigit))
        #expect(settings.webhookSecret() == first)
    }

    @Test func providerFollowsTheGateway() {
        let (settings, _, _) = fresh()
        #expect(settings.makeProvider()?.kind == .gowa)
        settings.gateway = .openwa
        #expect(settings.makeProvider()?.kind == .openwa)
        settings.setSecret(WhatsAppSettings.urlKey, "ftp://x")
        #expect(settings.makeProvider() == nil)
    }

    @Test func gowaRunsOnlyOnThisMacWithTheCredentialInTheEnvironment() throws {
        let (settings, _, secrets) = fresh(executable: ["/tmp/kobe-test/GOWA/gowa"])
        store(secrets, "whatsapp-api-key", "kobe:pw")
        let plan = try #require(settings.launchPlan())
        #expect(plan.binary == "/tmp/kobe-test/GOWA/gowa")
        #expect(plan.arguments == ["rest", "--host=127.0.0.1", "--port=47840", "--auto-download-media=false", "--os=Kobe"])
        #expect(plan.environment == ["APP_BASIC_AUTH": "kobe:pw", "APP_UI_ENABLED": "false"])
        #expect(!plan.arguments.joined().contains("pw"))

        settings.setSecret(WhatsAppSettings.urlKey, "http://192.168.1.2:47840")
        #expect(settings.launchPlan() == nil)
        settings.setSecret(WhatsAppSettings.urlKey, nil)
        settings.gateway = .openwa
        #expect(settings.launchPlan() == nil)
        settings.gateway = .gowa
        settings.autoStart = false
        #expect(settings.launchPlan() == nil)
        settings.autoStart = true
        settings.binaryPath = "/nope"
        #expect(settings.launchPlan() == nil)
    }

    @Test func gowaNeverStartsWithoutAPassword() throws {
        let (settings, _, _) = fresh(executable: ["/tmp/kobe-test/GOWA/gowa"])
        #expect(settings.credential == nil)
        let plan = try #require(settings.launchPlan())
        let made = try #require(plan.environment["APP_BASIC_AUTH"])
        #expect(made.hasPrefix("kobe:") && made.count == 5 + 48)
        #expect(settings.credential == made)  // stored, so the provider sends the same one
        #expect(try #require(settings.launchPlan()).environment["APP_BASIC_AUTH"] == made)  // and it stays
    }

    @Test func restartRule() {
        let now = Date()
        #expect(WAGOWARestart.decide(running: true, launchedWith: "a", signature: "a", lastStart: now, now: now) == .keep)
        #expect(WAGOWARestart.decide(running: true, launchedWith: "a", signature: "b", lastStart: now, now: now) == .restart)
        #expect(WAGOWARestart.decide(running: false, launchedWith: "a", signature: "a", lastStart: now.addingTimeInterval(-30), now: now) == .wait)
        #expect(WAGOWARestart.decide(running: false, launchedWith: "a", signature: "a", lastStart: now.addingTimeInterval(-61), now: now) == .start)
        #expect(WAGOWARestart.decide(running: false, launchedWith: nil, signature: "a", lastStart: now, now: now) == .start)
    }
}

@Suite struct WhatsAppSecretReadTests {
    private func flaky() -> (WhatsAppSettings, UserDefaults, FlakySecrets) {
        let defaults = UserDefaults(suiteName: "wa-test-\(UUID().uuidString)")!
        let secrets = FlakySecrets()
        let settings = WhatsAppSettings(defaults: defaults, secrets: secrets,
                                        folder: URL(fileURLWithPath: "/tmp/kobe-test/GOWA", isDirectory: true), isExecutable: { _ in false })
        return (settings, defaults, secrets)
    }

    @Test func aFailedReadIsRetriedNextTime() {
        let (settings, _, secrets) = flaky()
        _ = secrets.write(service: WhatsAppSettings.service, account: WhatsAppSettings.urlKey, data: Data("http://x".utf8))
        secrets.failures = 1
        #expect(settings.customURL == nil)
        #expect(settings.customURL == "http://x")
        #expect(secrets.reads == 2)
    }

    @Test func aFailedCredentialReadNeverTriggersTheMigration() {
        let (settings, defaults, secrets) = flaky()
        _ = secrets.write(service: WhatsAppSettings.service, account: WhatsAppSettings.credentialKey, data: Data("kobe:new".utf8))
        _ = secrets.write(service: WhatsAppSettings.service, account: WhatsAppSettings.legacyAuthKey, data: Data("kobe:old".utf8))
        secrets.failures = 1
        #expect(settings.credential == nil)  // not the old password, and nothing copied over the new one
        #expect(!defaults.bool(forKey: "whatsappCredentialMigrated"))
        #expect(secrets.inner.read(service: WhatsAppSettings.service, account: WhatsAppSettings.credentialKey) == Data("kobe:new".utf8))
        #expect(settings.credential == "kobe:new")
    }
}
