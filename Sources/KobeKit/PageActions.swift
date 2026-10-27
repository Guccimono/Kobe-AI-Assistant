import Foundation
import Observation

// What the pages do, without the views: the tier-0 actions and their 5 s undo, the ↻ spin, the page keyboard,
// the list search and Stripe's periods. The app wires these to the services and draws them.

/// The tier-0 buttons (spec §3.2, §3.5): exactly the clicked action, verbatim, no model in between. The user's
/// click or Return is the approval.
public enum WidgetAction: Equatable, Sendable {
    case whatsappReply(chat: String, text: String)
    case whatsappMarkRead(chat: String)
    case refresh(WidgetID)
    /// Stop on a run Kobe Agent started itself (the `work` snapshot's `stoppable` runs). Runs the app started stop
    /// by closing their own stream instead.
    case stopRun(id: String)
    /// The circle on a reminder (done) or its Undo (not done). Kobe App writes it to Reminders at once.
    case reminderDone(id: String, done: Bool)
    /// The Reminders page's add field, on Return: Kobe App writes it to Reminders at once (`list` nil: the default).
    case addReminder(ReminderDraft, list: String?)
}

/// Why an action didn't go, in the words the page shows in place.
public struct ActionError: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// Where the pages send their actions. Today the app's `ShimActionSink` calls the in-app services; plan 2 adds a
/// `RequestFileActionSink` that writes `requests/<uuid>.json` for Kobe Agent's `kobe-actions` daemon, and the
/// pages don't change.
@MainActor
public protocol ActionSink: AnyObject {
    func perform(_ action: WidgetAction) async -> Result<Void, ActionError>
}

/// Reversible actions wait 5 s before they go, so Undo can take them back (the shim's version of deleting a
/// request file that is still unprocessed). Pages draw the optimistic state from `waiting` and a refusal from
/// `failures`. App-owned, so leaving the page never drops an action the user already chose.
@MainActor
@Observable
public final class ActionQueue {
    public static let undoWindow: Duration = .seconds(5)
    /// After the actions went, the optimistic state stays this long: the store reads the rewritten snapshot 150 ms
    /// after it lands, and the row must not flicker back in between.
    public static let settleDelay: Duration = .seconds(1)

    public private(set) var pending: [UUID: [WidgetAction]] = [:]
    /// The first refusal per schedule; the page shows it in place of the undo chip until dismissed.
    public private(set) var failures: [UUID: String] = [:]
    /// Already handed to the sink: too late to undo.
    @ObservationIgnored private var performing: Set<UUID> = []
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private let perform: @MainActor (WidgetAction) async -> Result<Void, ActionError>

    public init(sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                perform: @escaping @MainActor (WidgetAction) async -> Result<Void, ActionError>) {
        self.sleep = sleep
        self.perform = perform
    }

    /// Every action still drawn optimistically (waiting out its undo, or just performed).
    public var waiting: [WidgetAction] { pending.values.flatMap { $0 } }

    @discardableResult
    public func schedule(_ actions: [WidgetAction]) -> UUID {
        let id = UUID()
        pending[id] = actions
        Task { [weak self] in await self?.run(id) }
        return id
    }

    /// True when it was taken back in time; false once the actions went (or for an unknown id).
    @discardableResult
    public func undo(_ id: UUID) -> Bool {
        guard pending[id] != nil, !performing.contains(id) else { return false }
        pending[id] = nil
        return true
    }

    public func dismissFailure(_ id: UUID) { failures[id] = nil }

    private func run(_ id: UUID) async {
        await sleep(Self.undoWindow)
        // Undone meanwhile: nothing goes.
        guard let actions = pending[id] else { return }
        performing.insert(id)
        defer { performing.remove(id) }
        var failure: String?
        for action in actions {
            if case .failure(let error) = await perform(action), failure == nil { failure = error.message }
        }
        if let failure {
            // The rows go back to what the snapshot says, and the reason shows where the undo was.
            failures[id] = failure
            pending[id] = nil
            return
        }
        await sleep(Self.settleDelay)
        pending[id] = nil
    }
}

/// Each page's ↻ (and ⌘R): which refreshes are running, so the icon spins until the snapshot moves or 20 s pass.
@MainActor
@Observable
public final class RefreshTracker {
    public private(set) var spins: [WidgetID: RefreshSpin] = [:]
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void

    public init(now: @escaping @MainActor () -> Date = { .now },
                sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.now = now
        self.sleep = sleep
    }

    /// A click with `current` the snapshot's date now. False (no second refresh) while one is still spinning.
    /// Each spin clears only itself at its timeout, so an older click's timer never stops a newer refresh.
    public func start(_ id: WidgetID, current: Date?) -> Bool {
        if isSpinning(id, current: current) { return false }
        let spin = RefreshSpin(startedAt: now(), baseline: current)
        spins[id] = spin
        Task { [weak self] in
            guard let self else { return }
            await self.sleep(.seconds(RefreshSpin.timeout))
            if self.spins[id] == spin { self.spins[id] = nil }
        }
        return true
    }

    public func isSpinning(_ id: WidgetID, current: Date?) -> Bool {
        spins[id]?.isSpinning(current: current, now: now()) ?? false
    }
}

/// The page keys (spec §6: every page is keyboard-complete).
public enum PageKey: Hashable, Sendable {
    case up, down, enter, escape, refresh, search
    /// ⌘H: hide the amounts (Stripe).
    case hide
    /// ← →: only pages that claim them get them (the Agenda's months).
    case left, right

    /// From the physical key code (so ⌘R and ⌘F work on AZERTY too). `plain`: no modifier; `command`: ⌘ alone.
    /// Esc is handled apart (it has its own path in the island).
    public init?(code: UInt16, command: Bool, plain: Bool) {
        switch code {
        case 126 where plain: self = .up
        case 125 where plain: self = .down
        case 123 where plain: self = .left
        case 124 where plain: self = .right
        case 36 where plain, 76 where plain: self = .enter
        case 15 where command: self = .refresh
        case 3 where command: self = .search
        case 4 where command: self = .hide
        default: return nil
        }
    }

    /// The keys a text field needs for itself: while one has the caret, only Esc and ⌘R reach the page.
    public var passesThroughTyping: Bool { self == .escape || self == .refresh }
}

/// One key press for the view that owns the keyboard. The serial makes two presses of the same key distinct.
public struct PageKeyEvent: Equatable, Sendable {
    public let key: PageKey
    public let owner: String
    public let serial: Int
}

/// The page on screen owns the keyboard: the island's keyDown monitor asks which keys it takes and posts them
/// here instead of going through SwiftUI focus, which a non-activating panel rarely has. One owner at a time; a
/// page that goes away releases only its own claim, so the order of one page's onDisappear and the next one's
/// onAppear doesn't matter.
@MainActor
@Observable
public final class PageKeyboard {
    public private(set) var event: PageKeyEvent?
    @ObservationIgnored public private(set) var owner: String?
    @ObservationIgnored private var keys: Set<PageKey> = []
    @ObservationIgnored private var serial = 0

    public nonisolated init() {}

    public func claim(_ owner: String, keys: Set<PageKey>) {
        self.owner = owner
        self.keys = keys
    }

    public func release(_ owner: String) {
        guard self.owner == owner else { return }
        self.owner = nil
        keys = []
    }

    public func handles(_ key: PageKey) -> Bool { owner != nil && keys.contains(key) }

    public func post(_ key: PageKey) {
        guard let owner else { return }
        serial += 1
        event = PageKeyEvent(key: key, owner: owner, serial: serial)
    }
}

/// ⌘F on a list page: a row matches when any of its fields contains the query, ignoring case.
public enum PageSearch {
    public static func matches(_ query: String, _ fields: [String?]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return fields.contains { $0?.localizedCaseInsensitiveContains(q) == true }
    }
}

/// Stripe's period switch. Raw values are the snapshot's `period`.
public enum StripePeriod: String, CaseIterable, Sendable {
    case today, sevenDays = "7d", thirtyDays = "30d"

    public var title: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7 d"
        case .thirtyDays: "30 d"
        }
    }

    /// Where the period starts: midnight today, or 7 / 30 days back.
    public func start(now: Date = .now, calendar: Calendar = .current) -> Date {
        switch self {
        case .today: calendar.startOfDay(for: now)
        case .sevenDays: now.addingTimeInterval(-7 * 86_400)
        case .thirtyDays: now.addingTimeInterval(-30 * 86_400)
        }
    }
}
