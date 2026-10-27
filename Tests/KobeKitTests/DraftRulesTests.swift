import Foundation
import Testing
@testable import KobeKit

@Suite struct DraftRulesTests {
    @Test func plainTextPersists() {
        #expect(DraftRules.persistable("Remind me to call Ana"))
        #expect(DraftRules.persistable(""))
    }

    @Test func keyAfterWhitespaceIsNotPersisted() {
        for key in ["sk-abc", "  \n SK-abc", "rk_live_1", "ghp_x", "github_pat_1", "xoxb-1",
                    "sk_live_abc", "sk_test_abc", "whsec_abc", "gho_abc", "ghs_abc", "ghu_abc"] {
            #expect(!DraftRules.persistable(key), "\(key)")
        }
    }

    @Test func tooLongIsNotPersisted() {
        #expect(DraftRules.persistable(String(repeating: "a", count: DraftRules.maxLength)))
        #expect(!DraftRules.persistable(String(repeating: "a", count: DraftRules.maxLength + 1)))
    }

    @MainActor @Test func settingsRoundTrip() {
        let suite = "DraftRulesTests.\(UUID().uuidString)"
        // The defaults objects are gone before the cleanup runs, so nothing rewrites the plist afterwards.
        do {
            let defaults = UserDefaults(suiteName: suite)!
            let settings = AppSettings(defaults: defaults)
            #expect(settings.returnHintsShown == 0 && settings.composerDraft == "")
            settings.returnHintsShown = 2
            settings.composerDraft = "half a thought"
            let again = AppSettings(defaults: defaults)
            #expect(again.returnHintsShown == 2 && again.composerDraft == "half a thought")
        }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist"))
    }
}
