import Foundation
import Testing
@testable import KobeKit

struct GoogleFormatTests {
    @Test func deltaPercent() {
        #expect(GoogleFormat.deltaPercent(1240, 1100) == .init(text: "+13 %", good: true))
        #expect(GoogleFormat.deltaPercent(700, 1100) == .init(text: "−36 %", good: false))
        #expect(GoogleFormat.deltaPercent(50, 50) == .init(text: "0 %", good: nil))
        #expect(GoogleFormat.deltaPercent(12, 0) == nil)
    }

    @Test func positionDeltaInverted() {
        // Lower is better: moving from 9.1 to 8.4 is good news.
        #expect(GoogleFormat.positionDelta(8.4, 9.1) == .init(text: "−0.7", good: true))
        #expect(GoogleFormat.positionDelta(10.0, 8.8) == .init(text: "+1.2", good: false))
        #expect(GoogleFormat.positionDelta(8.4, 8.4) == .init(text: "0.0", good: nil))
        #expect(GoogleFormat.positionDelta(8.4, 0) == nil)
    }

    @Test func numbers() {
        #expect(GoogleFormat.count(1240) == "1,240")
        #expect(GoogleFormat.count(312) == "312")
        #expect(GoogleFormat.position(8.44) == "8.4")
        #expect(GoogleFormat.position(0) == "—")
        #expect(GoogleFormat.calls(nil) == "—")
        #expect(GoogleFormat.calls(14) == "14")
    }

    @Test func siteFromSearchURL() {
        let url = "https://search.google.com/search-console/performance/search-analytics?resource_id=sc-domain%3Aexample.org"
        #expect(GoogleFormat.site(searchURL: url) == "example.org")
        #expect(GoogleFormat.site(searchURL: "https://search.google.com/x?resource_id=https%3A%2F%2Fwww.example.org%2F") == "www.example.org")
        #expect(GoogleFormat.site(searchURL: "nonsense") == nil)
    }
}
