import Testing
@testable import KobeKit

@Test func panelHeightsClamp() {
    #expect(PanelHeights.resolve(remembered: 0, defaultHeight: 500, screenHeight: 1000) == 500)
    #expect(PanelHeights.resolve(remembered: 2000, defaultHeight: 500, screenHeight: 1000) == 900)
    #expect(PanelHeights.resolve(remembered: 300, defaultHeight: 500, screenHeight: 1000) == 500)
}

@Test func newDefaults() {
    #expect(PanelHeights.notchDefault == 360)
    #expect(PanelHeights.notchWidthDefault == 780)
    #expect(PanelHeights.notchWidthRange == 640...1100)
}
