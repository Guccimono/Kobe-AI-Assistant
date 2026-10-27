import Foundation
import Testing
@testable import KobeKit

/// Counts Keychain reads, so the "read once" rule is checked.
final class CountingSecrets: SecretStoring, @unchecked Sendable {
    let inner = InMemorySecrets()
    var reads = 0
    func exists(service: String, account: String) -> Bool { inner.exists(service: service, account: account) }
    func fetch(service: String, account: String) -> SecretRead {
        reads += 1
        return inner.fetch(service: service, account: account)
    }
    func write(service: String, account: String, data: Data) -> Bool { inner.write(service: service, account: account, data: data) }
    func delete(service: String, account: String) { inner.delete(service: service, account: account) }
}

/// A Keychain whose next `failures` reads fail (locked, denied, interrupted) before it answers normally.
final class FlakySecrets: SecretStoring, @unchecked Sendable {
    let inner = InMemorySecrets()
    var failures = 0
    var reads = 0
    func exists(service: String, account: String) -> Bool { inner.exists(service: service, account: account) }
    func fetch(service: String, account: String) -> SecretRead {
        reads += 1
        if failures > 0 { failures -= 1; return .failed(errSecInteractionNotAllowed) }
        return inner.fetch(service: service, account: account)
    }
    func write(service: String, account: String, data: Data) -> Bool { inner.write(service: service, account: account, data: data) }
    func delete(service: String, account: String) { inner.delete(service: service, account: account) }
}

@Test func keyRoundTrip() {
    let key = HermesKey(store: InMemorySecrets(), account: "sam")
    #expect(key.save("  abc \n"))
    #expect(key.load() == "abc")
    #expect(key.isSet)
}

@Test func emptyKeyRejected() {
    let store = InMemorySecrets()
    let key = HermesKey(store: store, account: "sam")
    #expect(!key.save("  "))
    #expect(!store.exists(service: HermesKey.service, account: "sam"))
}

@Test func keyIsReadFromKeychainOnce() {
    let store = CountingSecrets()
    _ = store.write(service: HermesKey.service, account: "g", data: Data("k".utf8))
    let key = HermesKey(store: store, account: "g")
    _ = key.load()
    _ = key.load()
    #expect(store.reads == 1)
}

@Test func aFailedKeychainReadIsNotRememberedAsNoKey() {
    let store = FlakySecrets()
    _ = store.write(service: HermesKey.service, account: "g", data: Data("k".utf8))
    store.failures = 1
    let key = HermesKey(store: store, account: "g")
    #expect(key.load() == nil)
    #expect(key.load() == "k")  // asked again, not stuck on "no key" until relaunch
    #expect(store.reads == 2)
}

@Test func aMissingKeyIsRememberedAsMissing() {
    let store = FlakySecrets()
    let key = HermesKey(store: store, account: "g")
    #expect(key.load() == nil)
    #expect(key.load() == nil)
    #expect(store.reads == 1)
}

@Test func keysWithInnerWhitespaceAreRefused() {
    let store = InMemorySecrets()
    let key = HermesKey(store: store, account: "g")
    #expect(!key.save("abc def"))
    #expect(!key.save("abc\ndef"))
    #expect(!key.save("abc\tdef"))
    #expect(!store.exists(service: HermesKey.service, account: "g"))
    #expect(key.save("  abc-def\n"))
}

@Test func deleteForgetsTheKey() {
    let store = InMemorySecrets()
    let key = HermesKey(store: store, account: "g")
    #expect(key.save("abc"))
    key.delete()
    #expect(!key.isSet)
    #expect(!store.exists(service: HermesKey.service, account: "g"))
}

@Test func savingReplacesAnExistingKey() {
    let key = HermesKey(store: InMemorySecrets(), account: "g")
    #expect(key.save("old"))
    #expect(key.save("new"))
    #expect(key.load() == "new")
}

@MainActor @Test func defaultsMatchSpec() {
    let defaults = UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(settings.serverURL == "http://127.0.0.1:8642")
    let expected = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Kobe/exchange").path
    #expect(settings.exchangeFolder == expected)
    #expect(settings.exchange == ExchangeSettings(folder: expected, shared: false))
    #expect(!settings.engineSeparateUser)
    #expect(AppSettings.defaultServerURL == "http://127.0.0.1:8642")
    #expect(settings.openOnHover)
    #expect(settings.autoCloseSeconds == 15)
    #expect(!settings.soundOn)
    #expect(settings.soundVolume == 0.5)
    #expect(settings.notchHeight == 0)
    #expect(settings.notchWidth == 0)
    #expect(settings.quickAskHotkey == "ctrl+opt+space")
    #expect(settings.claudeWait == 90)
    #expect(settings.launchAtLogin)
}

@MainActor @Test func separateUserSwitchesTheExchangeFolderDefault() {
    let defaults = UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(ExchangeSettings.sharedFolder == "/Users/Shared/" + "hermes-" + "exchange")
    settings.engineSeparateUser = true
    #expect(settings.exchangeFolder == ExchangeSettings.sharedFolder)
    #expect(AppSettings(defaults: defaults).exchangeFolder == ExchangeSettings.sharedFolder)
    settings.engineSeparateUser = false
    #expect(settings.exchangeFolder == ExchangeSettings.defaultFolder)
    // A folder the person typed is theirs: the toggle leaves it.
    settings.exchangeFolder = "/tmp/mine"
    settings.engineSeparateUser = true
    #expect(settings.exchangeFolder == "/tmp/mine")
    settings.engineSeparateUser = false
    #expect(settings.exchangeFolder == "/tmp/mine")
}

@MainActor @Test func currentServerURLFollowsTheSetting() {
    let defaults = UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(settings.currentServerURL == URL(string: "http://127.0.0.1:8642"))
    settings.serverURL = "http://127.0.0.1:9000"
    #expect(settings.currentServerURL == URL(string: "http://127.0.0.1:9000"))
    #expect(AppSettings(defaults: defaults).currentServerURL == URL(string: "http://127.0.0.1:9000"))
}

@MainActor @Test func brainKeptFromHermesPersists() {
    let defaults = UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.brainKeptFromHermes)
    settings.brainKeptFromHermes = true
    #expect(AppSettings(defaults: defaults).brainKeptFromHermes)
}

@MainActor @Test func selectedBrainDefaultsToClaudeAndPersists() {
    let defaults = UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(settings.selectedBrain == .claude)
    settings.selectedBrain = .ollama
    #expect(AppSettings(defaults: defaults).selectedBrain == .ollama)
}

@MainActor @Test func autoCloseClampsToAllowed() {
    let defaults = UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    settings.autoCloseSeconds = 20
    #expect(settings.autoCloseSeconds == 15)
    settings.autoCloseSeconds = 5
    #expect(settings.autoCloseSeconds == 10)
    settings.autoCloseSeconds = 60
    #expect(settings.autoCloseSeconds == 30)
    #expect(AppSettings(defaults: defaults).autoCloseSeconds == 30)  // remembered
}

@MainActor @Test func notchAndMenuBarAreBothOnByDefault() {
    let settings = AppSettings(defaults: UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!)
    #expect(settings.showNotch)
    #expect(settings.showMenuBar)
}

@MainActor @Test func oneSurfaceAlwaysStaysOn() {
    let defaults = UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    settings.showNotch = false
    #expect(!settings.showNotch && settings.showMenuBar)
    settings.showMenuBar = false
    #expect(settings.showNotch && !settings.showMenuBar)  // turning off the last one turns the other back on
    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.showNotch && !reloaded.showMenuBar)
}

@MainActor @Test func hoverDelayDefaultsShortAndClamps() {
    let settings = AppSettings(defaults: UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!)
    #expect(settings.hoverDelay == 0.1)
    settings.hoverDelay = 3
    #expect(settings.hoverDelay == 0.6)
    settings.hoverDelay = -1
    #expect(settings.hoverDelay == 0)
}

@MainActor @Test func voiceIsOffByDefaultWithKokorosHeart() {
    let settings = AppSettings(defaults: UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!)
    #expect(!settings.voiceOn)
    #expect(settings.voiceName == "af_heart")
    #expect(settings.voiceSpeed == 1.0)
}

@MainActor @Test func macConnectionsAreOffByDefaultAndPersist() {
    let suite = "kobe-tests-\(UUID().uuidString)"
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    #expect(!settings.mailOn && !settings.agendaOn && !settings.remindersOn && !settings.notesOn)
    #expect(MacKind.allCases.allSatisfy { !settings.isOn($0) })
    settings.mailOn = true
    settings.setOn(.notes, true)
    let again = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    #expect(again.mailOn && again.notesOn && !again.agendaOn && !again.remindersOn)
    #expect(again.isOn(.mail) && again.isOn(.notes))
    UserDefaults().removePersistentDomain(forName: suite)
}
