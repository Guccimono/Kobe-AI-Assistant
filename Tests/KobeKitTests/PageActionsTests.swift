import Foundation
import Testing
@testable import KobeKit

/// A sleep the test wakes by hand, so the 5 s undo window and the 20 s refresh timeout run instantly.
@MainActor
final class ManualSleeper {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Wakes the oldest sleep only.
    func wakeFirst() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }
}

/// Lets the woken tasks run to their next suspension.
@MainActor
func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

/// A sink that records what it was asked and answers with `result`.
@MainActor
final class FakeSink {
    var done: [WidgetAction] = []
    var result: Result<Void, ActionError> = .success(())

    func perform(_ action: WidgetAction) async -> Result<Void, ActionError> {
        done.append(action)
        return result
    }
}

@MainActor
struct ActionQueueTests {
    let sleeper = ManualSleeper()
    let sink = FakeSink()

    func queue() -> ActionQueue {
        ActionQueue(sleep: { [sleeper] in await sleeper.sleep($0) }, perform: { [sink] in await sink.perform($0) })
    }

    @Test func aTickedReminderGoesAfterTheWindowAndUndoTakesItBack() async {
        let q = queue()
        let tick = q.schedule([.reminderDone(id: "r1", done: true)])
        await settle()
        #expect(q.undo(tick))
        sleeper.wakeFirst()
        await settle()
        #expect(sink.done.isEmpty)
        _ = q.schedule([.reminderDone(id: "r1", done: true)])
        await settle()
        sleeper.wakeFirst()
        await settle()
        #expect(sink.done == [.reminderDone(id: "r1", done: true)])
    }

    @Test func undoBeforeTheWindowEndsCancelsThePerform() async {
        let q = queue()
        let id = q.schedule([.whatsappMarkRead(chat: "a")])
        #expect(q.waiting == [.whatsappMarkRead(chat: "a")])
        await settle()
        #expect(q.undo(id))
        #expect(q.waiting.isEmpty)
        sleeper.wakeFirst()
        await settle()
        #expect(sink.done.isEmpty)
    }

    @Test func afterThePerformUndoIsRefusedAndTheOptimisticStateStays() async {
        let q = queue()
        let id = q.schedule([.whatsappMarkRead(chat: "a"), .whatsappMarkRead(chat: "b")])
        await settle()
        sleeper.wakeFirst()   // the 5 s window ends: both go
        await settle()
        #expect(sink.done == [.whatsappMarkRead(chat: "a"), .whatsappMarkRead(chat: "b")])
        #expect(!q.undo(id))
        // Still drawn as read until the rewritten snapshot has been read.
        #expect(q.waiting.count == 2)
        sleeper.wakeFirst()   // the settle delay
        await settle()
        #expect(q.waiting.isEmpty)
        #expect(q.failures.isEmpty)
    }

    @Test func aFailedActionKeepsItsReasonForThePage() async {
        sink.result = .failure(ActionError(message: "The gateway doesn't answer"))
        let q = queue()
        let id = q.schedule([.whatsappMarkRead(chat: "a")])
        await settle()
        sleeper.wakeFirst()
        await settle()
        // The row flips back at once, with the reason in place.
        #expect(q.waiting.isEmpty)
        #expect(q.failures[id] == "The gateway doesn't answer")
        q.dismissFailure(id)
        #expect(q.failures.isEmpty)
    }

    @Test func undoOfAnUnknownIdIsRefused() {
        #expect(!queue().undo(UUID()))
    }
}

@MainActor
struct RefreshTrackerTests {
    let sleeper = ManualSleeper()
    final class Now { var date = Date(timeIntervalSince1970: 1_000) }
    let now = Now()

    func tracker() -> RefreshTracker {
        RefreshTracker(now: { [now] in now.date }, sleep: { [sleeper] in await sleeper.sleep($0) })
    }

    @Test func aSecondClickWhileSpinningDoesNotFireAgain() async {
        let t = tracker()
        let old = Date(timeIntervalSince1970: 900)
        #expect(t.start(.stripe, current: old))
        now.date += 5
        #expect(!t.start(.stripe, current: old))
        #expect(t.isSpinning(.stripe, current: old))
        await settle()
        #expect(sleeper.count == 1)
    }

    @Test func theFirstTimeoutDoesNotStopALaterRefresh() async {
        let t = tracker()
        let old = Date(timeIntervalSince1970: 900)
        #expect(t.start(.vercel, current: old))
        await settle()
        // The file moved: done spinning; a new click starts a new refresh.
        let moved = Date(timeIntervalSince1970: 1_003)
        #expect(!t.isSpinning(.vercel, current: moved))
        now.date += 8
        #expect(t.start(.vercel, current: moved))
        await settle()
        sleeper.wakeFirst()   // the first click's 20 s
        await settle()
        #expect(t.isSpinning(.vercel, current: moved))
        now.date += 20
        sleeper.wakeFirst()
        await settle()
        #expect(t.spins[.vercel] == nil)
    }
}

@MainActor
@Test func pageKeyboardBelongsToOneOwner() {
    let k = PageKeyboard()
    #expect(!k.handles(.up))
    k.claim("whatsapp", keys: [.up, .down])
    #expect(k.handles(.up) && !k.handles(.escape))
    // The next page claimed first; the old one's late release is ignored.
    k.claim("stripe", keys: [.enter])
    k.release("whatsapp")
    #expect(k.handles(.enter) && k.owner == "stripe")
    k.post(.enter)
    #expect(k.event?.owner == "stripe" && k.event?.key == .enter)
    k.post(.enter)
    #expect(k.event?.serial == 2)
    k.release("stripe")
    #expect(k.owner == nil && !k.handles(.enter))
}

@Test func pageKeysFromPhysicalKeys() {
    #expect(PageKey(code: 126, command: false, plain: true) == .up)
    // ← → for the Agenda's months; never with a modifier.
    #expect(PageKey(code: 123, command: false, plain: true) == .left)
    #expect(PageKey(code: 124, command: false, plain: true) == .right)
    #expect(PageKey(code: 123, command: true, plain: false) == nil)
    #expect(PageKey(code: 125, command: false, plain: true) == .down)
    #expect(PageKey(code: 36, command: false, plain: true) == .enter)
    #expect(PageKey(code: 76, command: false, plain: true) == .enter)
    #expect(PageKey(code: 15, command: true, plain: false) == .refresh)
    #expect(PageKey(code: 3, command: true, plain: false) == .search)
    // ⇧Return, ⌥↑, plain R: not page keys.
    #expect(PageKey(code: 36, command: false, plain: false) == nil)
    #expect(PageKey(code: 15, command: false, plain: true) == nil)
    #expect(PageKey.escape.passesThroughTyping && PageKey.refresh.passesThroughTyping)
    #expect(!PageKey.enter.passesThroughTyping)
}

@Test func pageSearchMatchesAnyFieldIgnoringCase() {
    #expect(PageSearch.matches("", ["anything"]))
    #expect(PageSearch.matches("  ", [nil]))
    #expect(PageSearch.matches("menu", ["menuly-v4", "Menu export"]))
    #expect(PageSearch.matches("MEN", [nil, "menuly-web"]))
    #expect(!PageSearch.matches("docs", ["menuly-web", nil]))
}

@Test func stripePeriodStarts() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_792_765_690)   // 2026-10-23 14:28:10 UTC
    #expect(StripePeriod.today.start(now: now, calendar: calendar) == Date(timeIntervalSince1970: 1_792_713_600))
    #expect(StripePeriod.sevenDays.start(now: now, calendar: calendar) == now.addingTimeInterval(-7 * 86_400))
    #expect(StripePeriod.thirtyDays.start(now: now, calendar: calendar) == now.addingTimeInterval(-30 * 86_400))
    #expect(StripePeriod(rawValue: "7d") == .sevenDays && StripePeriod(rawValue: "1y") == nil)
    #expect(StripePeriod.allCases.map(\.title) == ["Today", "7 d", "30 d"])
}
