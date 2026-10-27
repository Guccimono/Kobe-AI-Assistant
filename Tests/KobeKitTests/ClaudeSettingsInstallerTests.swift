import Foundation
import Testing
@testable import KobeKit

private let hookPath = "/Applications/Kobe.app/Contents/MacOS/kobe-hook"
private func fixture(_ name: String) -> String { String(decoding: StubURLProtocol.fixture(name), as: UTF8.self) }
private func json(_ text: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }

@Test func replacesOldKobeEntries() throws {
    let plan = try ClaudeSettingsInstaller.plan(settings: fixture("settings_with_old_hook.json"), hookPath: hookPath, wait: 90)
    #expect(plan.removedCommands.count == 13)
    #expect(!plan.updated.contains("/Users/sam/"))
    let hooks = json(plan.updated)["hooks"] as! [String: Any]
    #expect(Set(hooks.keys) == Set(ClaudeSettingsInstaller.events))
    let pre = hooks["PreToolUse"] as! [[String: Any]]
    #expect(pre.contains { ($0["matcher"] as? String) == "AskUserQuestion" })
    let permission = (hooks["PermissionRequest"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]]
    #expect(permission[0]["timeout"] as? Int == 95)
    #expect(permission[0]["command"] as? String == "\"\(hookPath)\"")
    #expect(plan.updated.contains("say done"))  // other people's hooks stay
}

@Test func keepsUnrelatedKeys() throws {
    let plan = try ClaudeSettingsInstaller.plan(settings: fixture("settings_with_old_hook.json"), hookPath: hookPath, wait: 90)
    let updated = json(plan.updated)
    #expect(updated["model"] as? String == "opus")
    #expect((updated["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls:*)"])
}

@Test func missingFileCreatesHooks() throws {
    let plan = try ClaudeSettingsInstaller.plan(settings: nil, hookPath: hookPath, wait: 90)
    #expect(plan.original == "")
    #expect((json(plan.updated)["hooks"] as! [String: Any]).count == 12)
}

@Test func malformedThrows() {
    #expect(throws: ClaudeSettingsInstaller.InstallerError.malformed) {
        try ClaudeSettingsInstaller.plan(settings: fixture("settings_malformed.json"), hookPath: hookPath, wait: 90)
    }
}

@Test func applyBacksUpFirst() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kobe-claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("settings.json")
    let original = fixture("settings_with_old_hook.json")
    try original.write(to: url, atomically: true, encoding: .utf8)
    let plan = try ClaudeSettingsInstaller.plan(settings: original, hookPath: hookPath, wait: 90)
    let date = Date(timeIntervalSince1970: 1_792_600_000)
    let backup = try ClaudeSettingsInstaller.apply(plan, to: url, now: date)
    #expect(backup?.lastPathComponent.hasPrefix("settings.json.kobe-backup-") == true)
    #expect(try String(contentsOf: backup!, encoding: .utf8) == original)
    #expect(try String(contentsOf: url, encoding: .utf8) == plan.updated)
}

@Test func applyRefusesAFileChangedSinceThePlan() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kobe-claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("settings.json")
    let plan = try ClaudeSettingsInstaller.plan(settings: "{}", hookPath: hookPath, wait: 90)
    try #"{"model":"sonnet"}"#.write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: ClaudeSettingsInstaller.InstallerError.changedSinceShown) {
        try ClaudeSettingsInstaller.apply(plan, to: url, now: Date())
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == #"{"model":"sonnet"}"#)
}

@Test func idempotent() throws {
    let first = try ClaudeSettingsInstaller.plan(settings: fixture("settings_with_old_hook.json"), hookPath: hookPath, wait: 90)
    let second = try ClaudeSettingsInstaller.plan(settings: first.updated, hookPath: hookPath, wait: 90)
    #expect(second.updated == first.updated)
    #expect(second.removedCommands.allSatisfy { $0.contains("kobe-hook") })
}

@Test func uninstallRemovesOnlyKobe() throws {
    let installed = try ClaudeSettingsInstaller.plan(settings: fixture("settings_with_old_hook.json"), hookPath: hookPath, wait: 90)
    let removal = try ClaudeSettingsInstaller.uninstallPlan(settings: installed.updated, hookPath: hookPath)
    #expect(!removal.updated.contains("kobe-hook"))
    #expect(removal.updated.contains("say done"))
    #expect(json(removal.updated)["model"] as? String == "opus")
}

@Test func diffShowsRemovedAndAdded() {
    let plan = ClaudeSettingsPlan(original: "a\nb\nc", updated: "a\nc\nd", removedCommands: [], addedEvents: [])
    #expect(ClaudeSettingsInstaller.diff(plan) == "  a\n- b\n  c\n+ d")
}

@Test func installedWaitIsReadBack() throws {
    let plan = try ClaudeSettingsInstaller.plan(settings: "{}", hookPath: hookPath, wait: 120)
    #expect(ClaudeSettingsInstaller.installedWait(settings: plan.updated, hookPath: hookPath) == 120)
    #expect(ClaudeSettingsInstaller.installedWait(settings: "{}", hookPath: hookPath) == nil)
}
