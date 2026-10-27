import Foundation
import Testing
@testable import KobeKit

@Test func copyUsesTheName() {
    let c = Copy(name: "Mira")
    #expect(c.ask == "Ask Mira…" && c.thinking == "Mira is thinking…" && c.work == "Mira's work")
    #expect(c.needsYou == "Mira needs you" && c.replied == "Mira replied" && c.newChat == "New chat with Mira")
    #expect(c.memory == "Open Mira's memory" && c.askOrDrop == "Ask Mira… or drop a file here")
}

@Test func emptyNameFallsBackToKobe() {
    #expect(Copy(name: "   ").name == "Kobe" && Copy(name: "").ask == "Ask Kobe…")
}

@Test func helloIgnoresTheRoleForNow() {
    let line = "Hi. I'm here in your notch now. Want to start with your calendar or your inbox?"
    #expect(Copy(name: "Mira").hello(role: nil) == line && Copy(name: "Mira").hello(role: "Chief of staff") == line)
}

@MainActor @Test func copyReachesPureKobeKitCode() {
    let mira = Copy(name: "Mira")
    #expect(NowRanker.meta(updatedAt: nil, copy: mira) == "by Mira")
    #expect(SnapshotRules.metaText(.fresh(age: 120), source: mira.name) == "updated 2 min ago · Mira")
    #expect(ChatStore.describe(HermesError.offline, copy: mira) == "Mira is offline.")
    #expect(ChatStore.readable("session_active_turn", copy: mira).hasPrefix("Mira is still answering"))
    #expect(ChatEvent.decode(event: "run.failed", data: #"{"run_id":"r"}"#, copy: mira) == .failed("Mira stopped before finishing."))
    let session = try? JSONDecoder().decode(HermesSession.self, from: Data(#"{"id":"s1"}"#.utf8))
    #expect(session?.sourceLabel(copy: mira) == "Mira" && session?.sourceLabel == "Kobe")
}

@MainActor @Test func assistantProfilePersists() {
    let suite = "CopyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fresh = AppSettings(defaults: defaults)
    #expect(fresh.assistantName == "Kobe" && fresh.assistantRole == "" && fresh.assistantTone == .direct)
    fresh.assistantName = "Mira"
    fresh.assistantRole = "Chief of staff"
    fresh.assistantTone = .warm
    let again = AppSettings(defaults: defaults)
    #expect(again.assistantName == "Mira" && again.assistantRole == "Chief of staff" && again.assistantTone == .warm)
    #expect(again.copy.ask == "Ask Mira…")
}
