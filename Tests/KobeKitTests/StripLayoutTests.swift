import CoreGraphics
import Testing
@testable import KobeKit

@Test func orderAndKeys() {
    // Approved 2026-10-24: Mail after WhatsApp; ⌘0 (and Esc) is Home, ⌘1…⌘9 the connections.
    #expect(StripLayout.order == [.now, .whatsapp, .mail, .agenda, .reminders, .notes, .google, .stripe, .github, .vercel])
    #expect(StripLayout.key(for: .now) == 0)
    #expect(StripLayout.key(for: .whatsapp) == 1)
    #expect(StripLayout.key(for: .mail) == 2)
    #expect(StripLayout.key(for: .notes) == 5)
    #expect(StripLayout.key(for: .google) == 6)
    #expect(StripLayout.key(for: .vercel) == 9)
    // Not on the strip: no key.
    #expect(StripLayout.key(for: .work) == nil)
    #expect(StripLayout.key(for: .memory) == nil)
    #expect(StripLayout.id(forKey: 0) == .now)
    #expect(StripLayout.id(forKey: 1) == .whatsapp)
    #expect(StripLayout.id(forKey: 2) == .mail)
    #expect(StripLayout.id(forKey: 9) == .vercel)
    #expect(StripLayout.id(forKey: 10) == nil)
    #expect(StripLayout.id(forKey: -1) == nil)
    #expect(StripLayout.name(.mail) == "Mail")
    #expect(StripLayout.tint(.mail).hex == 0x1E90FF)
    #expect(StripLayout.icon(.mail) == .envelopeSimpleFill)
    for id in StripLayout.order { #expect(StripLayout.id(forKey: StripLayout.key(for: id)!) == id) }
}

@Test func stripGeometry() {
    #expect(StripLayout.step == 18)
    #expect(StripLayout.size == 28)
    #expect(StripLayout.raisedScale == 1.25)
    #expect(StripLayout.x(index: 0, raised: nil) == 0)
    #expect(StripLayout.x(index: 4, raised: nil) == 72)
}

@Test func raisedNeighboursSlide() {
    // Bound to locals first: inside #expect the mixed CGFloat/literal arithmetic compared unequal values of 64.0.
    let after: CGFloat = StripLayout.x(index: 3, raised: 2), afterRest: CGFloat = StripLayout.x(index: 3, raised: nil)
    let before: CGFloat = StripLayout.x(index: 1, raised: 2), beforeRest: CGFloat = StripLayout.x(index: 1, raised: nil)
    let itself: CGFloat = StripLayout.x(index: 2, raised: 2), itselfRest: CGFloat = StripLayout.x(index: 2, raised: nil)
    let last: CGFloat = StripLayout.x(index: 8, raised: 0), lastRest: CGFloat = StripLayout.x(index: 8, raised: nil)
    #expect(after - afterRest == 10)
    #expect(beforeRest - before == 10)
    #expect(itself == itselfRest)
    #expect(last - lastRest == 10)
}

@Test func labelCopy() {
    #expect(StripLayout.label(.google, status: .ok) == "Google · All good · ⌘6")
    #expect(StripLayout.label(.stripe, status: .needsYou) == "Stripe · Needs you · ⌘7")
    #expect(StripLayout.label(.github, status: .failed) == "GitHub · Failed · ⌘8")
    #expect(StripLayout.label(.agenda, status: .notSetUp) == "Agenda · Not set up · ⌘3")
    #expect(StripLayout.label(.now, status: nil) == "Home · ⌘0")
    #expect(StripLayout.label(.whatsapp, status: nil) == "WhatsApp · ⌘1")
    #expect(StripLayout.label(.work, status: .ok) == "Work · All good")
    #expect(StripLayout.label(.mail, status: .ok) == "Mail · All good · ⌘2")
    #expect(StripLayout.label(.mail, status: .ok, headline: "3 unread") == "Mail · 3 unread · ⌘2")
    #expect(StripLayout.label(.mail, status: nil, headline: "3 unread") == "Mail · 3 unread · ⌘2")
}

@Test func tintsMatchSpec() {
    #expect(StripLayout.tint(.now) == Theme.lime)
    #expect(StripLayout.tint(.whatsapp).hex == 0x25D366)
    #expect(StripLayout.tint(.stripe).hex == 0x635BFF)
    #expect(StripLayout.tint(.google).hex == 0x4285F4)
    #expect(StripLayout.tint(.agenda).hex == 0xF4505E)
    #expect(StripLayout.tint(.reminders).hex == 0xF5A524)
    #expect(StripLayout.tint(.notes).hex == 0xFFD60A)
    #expect(StripLayout.tint(.github).hex == 0xE5E7EB)
    #expect(StripLayout.tint(.vercel).hex == 0xF5F5F5)
}

/// Physical keys, so ⌘1 works on AZERTY (where the 1 key types "&") as on QWERTY.
@Test func digitFromKeyCode() {
    let row: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    let keypad: [UInt16: Int] = [82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
    for (code, digit) in row.merging(keypad, uniquingKeysWith: { a, _ in a }) {
        #expect(StripLayout.digit(forKeyCode: code) == digit, "key code \(code)")
    }
    #expect(StripLayout.digit(forKeyCode: 0) == nil)    // A
    #expect(StripLayout.digit(forKeyCode: 53) == nil)   // Esc
    #expect(StripLayout.digit(forKeyCode: 15) == nil)   // R
}
