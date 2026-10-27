import Foundation
import Testing
@testable import KobeKit

// The page keyboard: ↑↓ move one selection over the rows the page shows; Return runs the selected row.

@Test func downWrapsNever() {
    var s = PageSelection()
    s.move(.down, count: 3)
    #expect(s.index == 0)
    s.move(.down, count: 3)
    s.move(.down, count: 3)
    #expect(s.index == 2)
    // At the last row it stays: no wrap to the top.
    s.move(.down, count: 3)
    #expect(s.index == 2)
}

@Test func upFromNilGoesLast() {
    var s = PageSelection()
    s.move(.up, count: 4)
    #expect(s.index == 3)
    s.move(.up, count: 4)
    #expect(s.index == 2)
    var top = PageSelection(index: 0)
    top.move(.up, count: 4)
    #expect(top.index == 0)
}

@Test func moveInAnEmptyListSelectsNothing() {
    var s = PageSelection(index: 2)
    s.move(.down, count: 0)
    #expect(s.index == nil)
    s.move(.up, count: 0)
    #expect(s.index == nil)
}

@Test func clampAfterListShrinks() {
    var s = PageSelection(index: 5)
    s.clamp(count: 3)
    #expect(s.index == 2)
    s.clamp(count: 3)
    #expect(s.index == 2)
    s.clamp(count: 0)
    #expect(s.index == nil)
    var none = PageSelection()
    none.clamp(count: 4)
    #expect(none.index == nil)
}

@Test func currentIsTheSelectedRow() {
    let rows = ["a", "b", "c"]
    #expect(PageSelection().current(in: rows) == nil)
    #expect(PageSelection(index: 1).current(in: rows) == "b")
    // A stale index past the end reads as nothing, never a crash.
    #expect(PageSelection(index: 7).current(in: rows) == nil)
}

// ↻ spins until the snapshot's date moves or 20 s pass.

@Test func refreshSpinsUntilTheDateMovesOrTimeout() {
    let start = Date(timeIntervalSince1970: 1_000)
    let old = Date(timeIntervalSince1970: 900)
    let spin = RefreshSpin(startedAt: start, baseline: old)
    #expect(spin.isSpinning(current: old, now: start.addingTimeInterval(5)))
    #expect(!spin.isSpinning(current: Date(timeIntervalSince1970: 1_003), now: start.addingTimeInterval(5)))
    #expect(!spin.isSpinning(current: old, now: start.addingTimeInterval(20)))
    // No file before: the first file counts as the change.
    let fresh = RefreshSpin(startedAt: start, baseline: nil)
    #expect(fresh.isSpinning(current: nil, now: start.addingTimeInterval(1)))
    #expect(!fresh.isSpinning(current: start, now: start.addingTimeInterval(1)))
}

// Page copy helpers.

@Test func maskedNumberShowsTheEnds() {
    #expect(WAJID.masked("15550100142@s.whatsapp.net") == "+15 5 ·· ·· 01 42")
    #expect(WAJID.masked("15550100256:4@s.whatsapp.net") == "+15 5 ·· ·· 02 56")
    #expect(WAJID.masked("+44700900123") == "+44 7 ·· ·· 01 23")
    #expect(WAJID.masked("5215550100786:4@s.whatsapp.net") == "+52 1 ·· ·· 07 86")
    // Groups and short ids have no number to show.
    #expect(WAJID.masked("1203630@g.us") == nil)
    #expect(WAJID.masked("12345@s.whatsapp.net") == nil)
}

@Test func pageTimesAreRelativeUnderADayThenAbsolute() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_792_765_690)   // Fri 2026-10-23 14:28:10 UTC
    #expect(PageText.age(now.addingTimeInterval(-30), now: now) == "now")
    #expect(PageText.age(now.addingTimeInterval(-14 * 60), now: now) == "14 min")
    #expect(PageText.age(now.addingTimeInterval(-2 * 3600), now: now) == "2 h")
    #expect(PageText.age(now.addingTimeInterval(-6 * 86_400), now: now) == "6 d")
    // A payment today shows its clock time, yesterday says so, older ones their date.
    #expect(PageText.when(now.addingTimeInterval(-3 * 3600), now: now, calendar: calendar) == "11:28")
    #expect(PageText.when(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "yesterday")
    #expect(PageText.when(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar) == "Oct 20")
    // A day ahead (next payout, retry): the weekday within a week, else the date.
    #expect(PageText.day(now.addingTimeInterval(3 * 86_400), now: now, calendar: calendar) == "Mon")
    #expect(PageText.day(now.addingTimeInterval(20 * 86_400), now: now, calendar: calendar) == "Nov 12")
}
