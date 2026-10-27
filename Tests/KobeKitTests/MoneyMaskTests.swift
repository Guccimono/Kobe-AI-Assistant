import Foundation
import Testing
@testable import KobeKit

struct MoneyMaskTests {
    @Test func hidesAnAmountBankStyle() {
        #expect(MoneyMask.hidden("eur") == "€•••")
        #expect(MoneyMask.hidden("usd") == "$•••")
        #expect(MoneyMask.hidden("mxn") == "MX$•••")
        #expect(MoneyMask.hidden("chf") == "CHF •••")
    }

    @Test func masksAmountsInsideText() {
        #expect(MoneyMask.mask("€1,234.50 today · 3 payments") == "€••• today · 3 payments")
        #expect(MoneyMask.mask("Ana paid $40") == "Ana paid $•••")
        #expect(MoneyMask.mask("MX$1200 · Pro plan") == "MX$••• · Pro plan")
        #expect(MoneyMask.mask("-€12.5 pending") == "-€••• pending")
        #expect(MoneyMask.mask("CHF 300 pending") == "CHF ••• pending")
        // Numbers that aren't money stay.
        #expect(MoneyMask.mask("3 payments · retry Fri 24") == "3 payments · retry Fri 24")
        #expect(MoneyMask.mask("") == "")
    }

    @Test func amountIsHiddenOnlyWhenAsked() {
        #expect(MoneyMask.money(4050, "eur", hidden: false) == "€40.50")
        #expect(MoneyMask.money(4050, "eur", hidden: true) == "€•••")
    }

    @Test func commandHIsTheHideKey() {
        #expect(PageKey(code: 4, command: true, plain: false) == .hide)
        #expect(PageKey(code: 4, command: false, plain: true) == nil)
    }

    @MainActor @Test func hideAmountsPersists() {
        let suite = "MoneyMaskTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.hideAmounts)
        settings.hideAmounts = true
        #expect(AppSettings(defaults: defaults).hideAmounts)
    }
}
