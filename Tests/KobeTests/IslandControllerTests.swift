import AppKit
import Foundation
import Testing
@testable import KobeApp
@testable import KobeKit

/// The island headless: a fake panel, no windows and no event monitors; the pointer and keys are fed directly.
@MainActor
struct IslandControllerTests {
    private func make(api: FakeHermes = FakeHermes()) -> (AppModel, IslandController, FakePanel, () -> Void) {
        let (model, cleanup) = TestApp.model(api: api)
        let panel = FakePanel()
        let controller = IslandController(app: model, panel: panel, watchesEvents: false)
        model.controller = controller
        return (model, controller, panel, cleanup)
    }

    private static let escape = IslandKey(code: 53, flags: [])
    private static let pin = IslandKey(code: 35, flags: .command, characters: "p")
    /// ⌘\ on a US layout: the physical key 42.
    private static let foldUS = IslandKey(code: 42, flags: .command, characters: "\\")
    /// ⌘\ where the backslash is not key 42 (French AZERTY: ⌥⇧/): read by its character.
    private static let foldAZERTY = IslandKey(code: 47, flags: [.command, .option, .shift], characters: "\\")

    @Test func hoverShowsWingsClickOpens() async {
        let (model, controller, panel, cleanup) = make()
        defer { cleanup() }
        #expect(model.island.phase == .resting)
        controller.pointerMoved(inside: true)
        #expect(await TestApp.eventually { model.island.phase == .compact })
        controller.clickedInside()
        #expect(model.island.phase == .expanded)
        #expect(panel.isKeyWindow)
    }

    @Test func closeOnLeaveOffHoldsOpen() async {
        let (model, controller, _, cleanup) = make()
        defer { cleanup() }
        model.settings.closeOnLeave = false
        controller.pointerMoved(inside: true)
        controller.clickedInside()
        #expect(model.island.phase == .expanded)
        controller.pointerMoved(inside: false)
        // Past the fold delay, it is still open.
        try? await Task.sleep(for: .seconds(NotchMachine.foldDelay + 0.3))
        #expect(model.island.phase == .expanded)

        // With the setting on, the same exit folds it.
        model.settings.closeOnLeave = true
        controller.pointerMoved(inside: true)
        controller.pointerMoved(inside: false)
        #expect(await TestApp.eventually { model.island.phase != .expanded })
    }

    @Test func escapeGoesHomeThenCloses() {
        let (model, controller, _, cleanup) = make()
        defer { cleanup() }
        model.openPage(.stripe)
        #expect(model.island.phase == .expanded)
        #expect(model.island.overlay == .page(.stripe))
        #expect(controller.handleKey(Self.escape))
        #expect(model.island.phase == .expanded)
        #expect(model.island.overlay == .none)
        #expect(controller.handleKey(Self.escape))
        #expect(model.island.phase != .expanded)
        // Closed, Esc is no longer the island's.
        #expect(!controller.handleKey(Self.escape))
    }

    // MARK: Reopen where you left off

    @Test func reopensOnTheLastPageForAWhile() {
        let (model, controller, _, cleanup) = make()
        defer { cleanup() }
        model.settings.resumeMinutes = 5
        model.openPage(.notes)
        controller.close()
        #expect(model.island.overlay == .none)
        controller.open()
        #expect(model.island.overlay == .page(.notes))
        // Opening for something else (another page's key) wins.
        controller.close()
        model.openPage(.mail)
        #expect(model.island.overlay == .page(.mail))
        // Folded on Home: Home next time.
        model.goHome()
        controller.close()
        controller.open()
        #expect(model.island.overlay == .none)
        // Off: always Home.
        model.settings.resumeMinutes = 0
        model.openPage(.notes)
        controller.close()
        controller.open()
        #expect(model.island.overlay == .none)
    }

    // MARK: Pin

    @Test func commandPPinsTheOpenNotch() async {
        let (model, controller, _, cleanup) = make()
        defer { cleanup() }
        // Closed, ⌘P is not the island's.
        #expect(!controller.handleKey(Self.pin))
        model.goHome()
        #expect(controller.handleKey(Self.pin))
        #expect(model.island.pinned)
        // Pinned: the pointer leaving keeps it open.
        controller.pointerMoved(inside: true)
        controller.pointerMoved(inside: false)
        try? await Task.sleep(for: .seconds(NotchMachine.foldDelay + 0.3))
        #expect(model.island.phase == .expanded)
        // ⌘P again unpins (and, with the pointer away, it folds).
        #expect(controller.handleKey(Self.pin))
        #expect(!model.island.pinned)
        try? await Task.sleep(for: .seconds(NotchMachine.foldDelay + 0.3))
        #expect(model.island.phase != .expanded)
        // Esc closes and unpins.
        model.goHome()
        _ = controller.handleKey(Self.pin)
        _ = controller.handleKey(Self.escape)
        #expect(!model.island.pinned)
    }

    // MARK: ⌘\ and the approval

    @Test func commandBackslashFoldsNowOnAnyLayout() {
        let (model, controller, _, cleanup) = make()
        defer { cleanup() }
        model.goHome()
        model.island.homeMode = .split
        #expect(model.island.expanded)
        #expect(controller.handleKey(Self.foldUS))
        #expect(model.island.homeMode == .writing)
        #expect(controller.handleKey(Self.foldAZERTY))
        #expect(model.island.homeMode == .split)
        // Another ⌘ key with that physical position but another character, and no backslash: not the fold.
        #expect(!controller.handleKey(IslandKey(code: 47, flags: .command, characters: ".")))
        #expect(model.island.homeMode == .split)
    }

    @Test func escapeWhileWritingBringsNowBack() {
        let (model, controller, _, cleanup) = make()
        defer { cleanup() }
        model.goHome()
        model.island.homeMode = .writing
        model.composerDraft = "Reply to Ana"
        #expect(controller.handleKey(Self.escape))
        #expect(model.island.homeMode == .split && model.island.expanded)
        _ = controller.handleKey(Self.escape)
        #expect(!model.island.expanded)
        // An empty field: Esc closes the writing-first Home in one press.
        model.goHome()
        model.island.homeMode = .writing
        model.composerDraft = ""
        _ = controller.handleKey(Self.escape)
        #expect(!model.island.expanded)
    }

    @Test func homeOpensOnTheChosenLayout() {
        let (model, controller, _, cleanup) = make()
        defer { cleanup() }
        model.settings.resumeMinutes = 0
        model.island.homeMode = .split
        controller.open()
        // Nothing waits in the demo-free test folder: writing first.
        #expect(model.island.homeMode == .writing)
        controller.close()
        model.settings.homeStart = .now
        controller.open()
        #expect(model.island.homeMode == .reading)
        controller.close()
        model.settings.homeStart = .split
        controller.open()
        #expect(model.island.homeMode == .split)
    }

    @Test func anApprovalNeverHidesTheChat() async {
        let api = FakeHermes()
        let (model, controller, _, cleanup) = make(api: api)
        defer { cleanup() }
        #expect(await TestApp.approvalWaiting(model, api: api))
        model.goHome()
        #expect(model.needsAnswer)
        model.settings.homeStart = .now
        controller.close()
        controller.open()
        #expect(model.island.homeMode == .split)
        for _ in 0..<3 {
            _ = controller.handleKey(Self.foldUS)
            #expect(model.island.homeMode != .reading)
        }
        model.foldChat()
        #expect(model.island.homeMode != .reading)
    }

    @Test func approvalHotKeyWithFoldedChatOpensTheWorkPage() async {
        let api = FakeHermes()
        let (model, _, _, cleanup) = make(api: api)
        defer { cleanup() }
        #expect(await TestApp.approvalWaiting(model, api: api))
        model.goHome()
        #expect(model.hotKeyTarget == .approval)
        // Folded some other way (the approval came after the fold, a card that never unfolded it): not on screen.
        model.island.homeMode = .reading
        #expect(model.hotKeyTarget == nil)
        // Even a stale "unlocked" report from a card that is gone can't let the hotkey allow.
        model.reportApprovalLock(UUID(), locked: false)
        try? await Task.sleep(for: .seconds(0.35))
        model.hotKey(allow: true)
        #expect(model.approvalsToday == 0)
        #expect(model.island.overlay == .page(.work))
        // On the work page the card is on screen again: the hotkey targets it.
        #expect(model.hotKeyTarget == .approval)
    }

    // MARK: The composer's caret

    @Test func chatPathsPutTheCaretInTheComposer() async {
        let (model, controller, panel, cleanup) = make()
        defer { cleanup() }
        let session = HermesSession(id: "s1", source: "api_server", model: nil, title: "Menu prices", lastActive: nil,
                                    preview: nil, messageCount: 0)
        let paths: [(String, () -> Void)] = [
            ("Open in chat", { model.openQuickAskInChat() }),
            ("New chat", { model.newChat() }),
            ("A chat from the list", { model.openChat(session) }),
        ]
        for (name, path) in paths {
            controller.close()
            model.showOverlay(.chatsList)
            // Quick ask itself is set directly: showing it activates the app, which a test process has no NSApp for.
            if name == "Open in chat" { model.island.overlay = .quickAsk }
            model.island.homeMode = .reading
            model.composerFocusPending = false
            let keyBefore = panel.madeKey
            path()
            #expect(model.composerFocusPending, "\(name)")
            #expect(panel.madeKey > keyBefore, "\(name)")
            #expect(model.island.homeMode != .reading, "\(name)")
            #expect(model.island.overlay == .none, "\(name)")
            #expect(model.island.expanded, "\(name)")
        }
    }

    // MARK: Drags

    @Test func dragPassingOverNeverNavigates() {
        let (model, controller, panel, cleanup) = make()
        defer { cleanup() }
        model.openWhatsApp(chat: "15550001111@s.whatsapp.net")
        let keyBefore = panel.madeKey
        controller.dragEntered()
        controller.dragExited()
        // Still on the conversation, nothing took the keyboard or asked for the caret.
        #expect(model.island.overlay == .page(.whatsapp))
        #expect(model.whatsappChat == "15550001111@s.whatsapp.net")
        #expect(!model.composerFocusPending)
        #expect(panel.madeKey == keyBefore)

        // Closed: a drag opens it, and leaving without dropping folds it again.
        controller.close()
        controller.dragEntered()
        #expect(model.island.expanded)
        #expect(model.island.overlay == .page(.whatsapp) || model.island.overlay == .none)
        #expect(!model.composerFocusPending)
        controller.dragExited()
        #expect(!model.island.expanded)

        // An actual drop goes Home with the caret in the composer.
        controller.dragEntered()
        #expect(controller.drop(text: "Ask about this"))
        #expect(model.island.overlay == .none)
        #expect(model.composerFocusPending)
        #expect(model.composerDraft == "Ask about this")
    }
}
