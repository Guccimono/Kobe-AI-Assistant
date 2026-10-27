import AppKit
import Testing
@testable import KobeKit

@Test func coloursMatchSpec() {
    #expect(Theme.lime.hex == 0xC7F41E)
    #expect(Theme.amber.hex == 0xF5A524)
    #expect(Theme.red.hex == 0xF4505E)
    #expect(Theme.green.hex == 0x34D399)
}

@Test func everyIconShipsAndLoads() {
    for icon in PhosphorIcon.allCases {
        let url = icon.url()
        #expect(url != nil, "missing \(icon.rawValue)")
        if let url { #expect(NSImage(contentsOf: url) != nil, "unreadable \(icon.rawValue)") }
    }
}

@Test func kitTokensExist() {
    #expect(Theme.glass.alpha == 0.06)
    #expect(Theme.glassActive.alpha == 0.10)
    #expect(Theme.glassHighlight.alpha == 0.12)
    #expect(Theme.glass.rgb.hex == 0xFFFFFF)
    #expect(Radius.row == 8)
    #expect(Radius.chip == 8)
    #expect(Radius.button == 10)
    #expect(Radius.capsule == 999)
    #expect(Type.title == Type.Spec(size: 15, weight: .bold))
    #expect(Type.kpi.size == 20)
    #expect(Type.eyebrow.size == 10.5)
}

@Test func limeIsTheOnlyAccent() {
    #expect(Theme.lime.hex == 0xC7F41E)
}
