import AppKit
import SwiftUI
import KobeKit

/// Borderless, transparent panel above the menu bar, on every Space and over full-screen apps. It only becomes
/// key while the island is open, so typing works without pulling focus from the app you're in.
final class IslandPanel: NSPanel {
    var allowsKey: () -> Bool = { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        // The island is black in every mode, so its content always uses dark colours.
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { allowsKey() }
    override var canBecomeMain: Bool { false }
}

/// What the controller asks of its window: `IslandPanel` in the app, a fake in the tests (no window on screen).
@MainActor
protocol PanelProtocol: AnyObject {
    var allowsKey: () -> Bool { get set }
    var contentView: NSView? { get set }
    var ignoresMouseEvents: Bool { get set }
    var frame: NSRect { get }
    var isVisible: Bool { get }
    var isKeyWindow: Bool { get }
    var firstResponder: NSResponder? { get }
    func setFrame(_ frameRect: NSRect, display flag: Bool)
    func orderFrontRegardless()
    func orderOut(_ sender: Any?)
    func makeKey()
    func resignKey()
}

extension IslandPanel: PanelProtocol {}

/// Lets buttons react to the first click even though the panel isn't key yet.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Holds the SwiftUI view, the mouse tracking area and the drop target.
final class IslandContainerView: NSView {
    var onMove: ((NSPoint) -> Void)?
    var onExit: (() -> Void)?
    var onDropFiles: (([URL]) -> Bool)?
    var onDropText: ((String) -> Bool)?
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func text(_ info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty || text(sender) != nil else { return [] }
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty && text(sender) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExited?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        if !urls.isEmpty { return onDropFiles?(urls) ?? false }
        if let text = text(sender) { return onDropText?(text) ?? false }
        return false
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installTrackingArea() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); installTrackingArea() }

    private func installTrackingArea() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// The parts of a keyDown the island reads.
struct IslandKey: Sendable {
    let code: UInt16
    let flags: NSEvent.ModifierFlags
    /// The character the key typed, when it is the one a shortcut is read by (the backslash of ⌘\).
    var characters: String? = nil
    /// Caps Lock, Fn and the keypad flag do not change what ⌘1 means.
    static let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// ⌘\: ⌘ and the backslash character, whatever key and extra modifiers type it on this layout (French AZERTY:
    /// ⌥⇧/), or the US backslash key (42) with ⌘ alone.
    var isChatFold: Bool {
        guard flags.contains(.command), !flags.contains(.control) else { return false }
        return characters == "\\" || (code == 42 && flags == .command)
    }

    /// ⌘P: ⌘ and the "p" character on any layout, or the US P key (35) with ⌘ alone.
    var isPin: Bool {
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        return characters?.lowercased() == "p" || (code == 35 && flags == .command)
    }

    /// The backslash when either reading of the event gives it, otherwise what the key types without modifiers.
    static func characters(typed: String?, ignoringModifiers: String?) -> String? {
        typed == "\\" ? typed : ignoringModifiers
    }
}

/// The island, driven by NotchMachine (ported from the old Kobe): hover spreads the band into wings, a click opens
/// it, leaving folds it after a short delay unless pinned, busy or an approval waits.
@MainActor
final class IslandController {
    let model: IslandModel
    private let app: AppModel
    private let panel: any PanelProtocol
    private let container = IslandContainerView()
    private var hovering = false
    private var foldWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var screenObserver: Any?
    /// The island opened itself for an approval or a Claude card; it folds back once that's answered.
    private var openedByItself = false
    /// The island opened because a drag passed over it; it folds if the drag leaves without dropping.
    private var openedForDrag = false
    /// The app that was in front when quick ask took the keyboard; it gets it back when quick ask closes.
    private var previousApp: NSRunningApplication?

    /// With "Show in the notch" off, the panel hides once the fold (0.34 s) is done.
    static let hideDelay: TimeInterval = 0.4

    convenience init(app: AppModel) {
        self.init(app: app, panel: IslandPanel(), watchesEvents: true)
    }

    /// `watchesEvents` false (the tests): no screen observer and no event monitors, the pointer and keys are fed in.
    init(app: AppModel, panel: any PanelProtocol, watchesEvents: Bool) {
        self.app = app
        self.panel = panel
        model = app.island
        let hosting = FirstMouseHostingView(rootView: IslandRoot(app: app, island: app.island))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.onMove = { [weak self] _ in self?.trackPointer() }
        container.onExit = { [weak self] in self?.trackPointer() }
        container.onDropFiles = { [weak self] urls in self?.drop(files: urls) ?? false }
        container.onDropText = { [weak self] text in self?.drop(text: text) ?? false }
        container.onDragEntered = { [weak self] in self?.dragEntered() }
        container.onDragExited = { [weak self] in self?.dragExited() }
        panel.contentView = container
        panel.allowsKey = { [weak self] in self?.model.phase == .expanded }
        panel.setFrame(fixedFrame, display: true)
        panel.ignoresMouseEvents = true
        hosting.frame = container.bounds
        panel.orderFrontRegardless()
        if watchesEvents { watchEvents() }
        trackActivity()
        trackDraft()
        trackSize()
        trackEnabled()
    }

    private func watchEvents() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // No screen for a moment (lid closed, a display unplugged): keep the last geometry until one is back.
                guard let self, let geometry = NotchGeometry.current() else { return }
                self.model.geometry = geometry
                self.panel.setFrame(self.fixedFrame, display: true)
            }
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window === self.panel { self.clickedInside() } else { self.clickedOutside() }
            }
            return event
        }) { monitors.append(monitor) }
        // Esc goes Home from a page, Chat or a menu, and closes the island (and unpins it) from Home, unless
        // something waits for an answer. ⌘1…⌘9 open the strip's pages, ⌘0 goes Home; the page keys go to the
        // page on screen (`PageKeyboard`). Only while open, only for
        // the island's own window; the keys are consumed but the first responder is never touched, so the
        // composer keeps its caret.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            // NSEvent is not Sendable: only its values cross into the main-actor code.
            let key = IslandKey(code: event.keyCode, flags: event.modifierFlags.intersection(IslandKey.modifiers),
                                characters: IslandKey.characters(typed: event.characters,
                                                                 ignoringModifiers: event.charactersIgnoringModifiers))
            return MainActor.assumeIsolated { self.handleKey(key) } ? nil : event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let flags = event.modifierFlags.intersection(IslandKey.modifiers)
            MainActor.assumeIsolated { self?.commandChanged(flags) }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(monitor) }
        // The window is large and click-through; the pointer decides when it takes the mouse (over the island only).
        // Event-driven, so nothing runs while the mouse is still.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.trackPointer() }
            return event
        }) { monitors.append(monitor) }
    }

    /// Settings › General › Show in the notch: off hides the island completely.
    private func trackEnabled() {
        let enabled = withObservationTracking { app.settings.showNotch } onChange: { [weak self] in
            Task { @MainActor in self?.trackEnabled() }
        }
        if enabled {
            panel.orderFrontRegardless()
        } else if !model.expanded {
            panel.orderOut(nil)
        }
    }

    // MARK: Public

    func open() {
        send(.openRequested)
        panel.makeKey()
    }

    /// `restoringFocus`: quick ask hands the keyboard back to the app it took it from (not after a click elsewhere,
    /// which already chose the next app).
    func close(restoringFocus: Bool = true) {
        model.pinned = false
        openedByItself = false
        let wasQuickAsk = model.overlay == .quickAsk
        if model.overlay == .quickAsk || model.overlay == .chatsList { model.overlay = .none }
        send(.closeRequested)
        if panel.isKeyWindow { panel.resignKey() }
        if wasQuickAsk, let previous = previousApp, previous.isTerminated == false, restoringFocus {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
        previousApp = nil
    }

    func show(_ tab: IslandTab) {
        model.tab = tab
        if model.overlay != .claude { model.overlay = .none }
        if !model.expanded { send(.openRequested) }
    }

    /// A notification: the wide band beside the notch (or the card itself if the notch is already open).
    func notify() {
        if !app.settings.showNotch { panel.orderFrontRegardless() }
        send(.notified)
    }

    func showOverlay(_ overlay: IslandOverlay) {
        model.overlay = overlay
        if !model.expanded {
            // Opened for a Claude card, not by the user: it folds back once the card is answered.
            if overlay == .claude { openedByItself = true }
            send(.openRequested)
        }
        if overlay == .quickAsk {
            if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
            NSApp.activate()
            panel.makeKey()
        }
    }

    /// ⌥⌘Y / ⌥⌘N on the band (or with the request off screen): the notch opens on Kobe's work page, where the
    /// waiting request is read first, and folds back once answered if it opened for it.
    func openForAnswer() {
        model.overlay = .page(.work)
        guard !model.expanded else { return }
        openedByItself = true
        send(.openRequested)
    }

    func togglePin() {
        model.pinned.toggle()
        if !model.pinned, !hovering { send(.hoverLeft) }
    }

    // MARK: Drags

    /// A drag over the island only opens it: passing over never navigates, takes the keyboard or leaves the page
    /// on screen. Only an actual drop goes Home (`drop`).
    func dragEntered() {
        openedForDrag = !model.expanded
        guard openedForDrag else { return }
        send(.openRequested)
    }

    func dragExited() {
        guard openedForDrag, !hovering, !app.needsAnswer else { return }
        openedForDrag = false
        close()
    }

    func drop(files urls: [URL]) -> Bool {
        openedForDrag = false
        return app.dropFiles(urls)
    }

    func drop(text: String) -> Bool {
        openedForDrag = false
        return app.dropText(text)
    }

    // MARK: Keys

    /// True when the key was the island's (Esc, ⌘P, ⌘0…⌘9) and is used up.
    func handleKey(_ key: IslandKey) -> Bool {
        guard model.expanded else { return false }
        if key.code == 53 {
            guard !app.needsAnswer else { return false }
            // A page that takes Esc itself: a WhatsApp conversation goes back to its list, a search closes.
            if app.pageKeys.handles(.escape) {
                app.pageKeys.post(.escape)
                return true
            }
            // Mid-draft with Now folded: Esc brings Now back before it closes anything.
            if model.overlay == .none,
               let back = HomeLayout.escape(model.homeMode, hasDraft: !app.composerDraft.isEmpty) {
                model.homeMode = back
                return true
            }
            switch model.overlay {
            case .page, .chatsList: app.goHome()
            default: close()  // Home, quick ask, a Claude card
            }
            return true
        }
        // ⌘\ folds Now to its rail to write, and brings it back. It never folds the chat (the fold button does),
        // so Kobe's approval card stays in view.
        if key.isChatFold, model.overlay == .none || model.overlay == .page(.now) {
            model.homeMode = HomeLayout.toggled(model.homeMode)
            return true
        }
        // ⌘P pins the open notch (it stays open when the pointer leaves) and unpins it.
        if key.isPin, model.overlay != .quickAsk {
            togglePin()
            return true
        }
        // The page on screen (or Home's Now) owns ↑↓, Return, ⌘R and ⌘F. A text field with the caret keeps every
        // key but ⌘R: typing never moves a selection or opens a row.
        if model.overlay != .quickAsk, let pageKey = PageKey(code: key.code, flags: key.flags), app.pageKeys.handles(pageKey) {
            if panel.firstResponder is NSText, !pageKey.passesThroughTyping { return false }
            app.pageKeys.post(pageKey)
            return true
        }
        // Quick ask is its own small surface without the strip.
        guard model.overlay != .quickAsk,
              key.flags == .command,
              let digit = StripLayout.digit(forKeyCode: key.code), let id = StripLayout.id(forKey: digit)
        else { return false }
        app.openPage(id)
        return true
    }

    private var commandHold: DispatchWorkItem?

    /// ⌘ held alone for 0.3 s while open shows the strip's label; releasing it (or any other modifier) hides it.
    /// One-shot work item, nothing runs while the key is up.
    private func commandChanged(_ flags: NSEvent.ModifierFlags) {
        let commandOnly = flags == .command
        commandHold?.cancel()
        commandHold = nil
        guard commandOnly, model.expanded else { model.commandHeld = false; return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.expanded else { return }
            self.model.commandHeld = true
        }
        commandHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// The composer only takes the caret in a key window: after a drop, the island takes the keyboard (a
    /// non-activating panel, so the app in front stays in front).
    func takeKeyboard() {
        guard model.expanded else { return }
        panel.makeKey()
    }

    // MARK: State machine

    private var context: NotchContext {
        // A WhatsApp reply being written, or "close when the pointer leaves" off, holds the open notch like the pin
        // (the wings still fold; a click outside, Esc and ✕ still close).
        let held = app.whatsapp.hasDraft || (!app.settings.closeOnLeave && model.phase == .expanded)
        return NotchContext(pinned: model.pinned || held, hovering: hovering, approval: app.needsAnswer,
                            notice: app.banner != nil)
    }

    /// The page the notch last folded on, to reopen there for `resumeMinutes`.
    private var resume = ResumePage()

    private func send(_ event: NotchEvent) {
        let transition = NotchMachine.reduce(model.phase, event, context)
        if transition.cancelFold { foldWork?.cancel(); foldWork = nil }
        if transition.scheduleFold {
            foldWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.send(.foldTimerFired) }
            foldWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchMachine.foldDelay, execute: work)
        }
        guard transition.phase != model.phase else { return }
        // With "Show in the notch" off, the island still appears when it opens (an answer, a hotkey, Settings),
        // and hides again once it has folded.
        if transition.phase == .expanded, !app.settings.showNotch { panel.orderFrontRegardless() }
        if transition.phase == .compact, !app.settings.showNotch { panel.orderFrontRegardless() }
        if transition.phase == .resting, !app.settings.showNotch {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay) { [weak self] in
                // Only if it is still folded: a band or an opening that came in the meantime keeps it on screen.
                guard let self, self.model.phase == .resting, !self.app.settings.showNotch else { return }
                self.panel.orderOut(nil)
            }
        }
        // Opening: Home takes the layout the settings ask for (before the reply notice is cleared, which keeps a
        // folded chat open for it).
        if transition.phase == .expanded, model.phase != .expanded { model.homeMode = app.homeOpening }
        if transition.phase == .expanded, model.phase == .compact { app.replyNotice = nil }
        // Folding: remember the page. Opening on nothing in particular: back to it while it's recent.
        if model.phase == .expanded {
            if case .page(let id) = model.overlay { resume.folded(on: id, at: .now) } else { resume.folded(on: nil, at: .now) }
        } else if transition.phase == .expanded, model.overlay == .none,
                  let id = resume.page(now: .now, minutes: app.settings.resumeMinutes) {
            model.overlay = .page(id)
        }
        // Whatever waits is only now in view: its hotkeys count 0.3 s from here.
        if transition.phase == .expanded { app.arm() }
        let growing = IslandModel.rank(transition.phase) > IslandModel.rank(model.phase)
        withAnimation(growing ? Animations.open : Animations.close) { model.phase = transition.phase }
        if transition.phase != .expanded {
            commandHold?.cancel()
            model.commandHeld = false
            if panel.isKeyWindow { panel.resignKey() }
            if transition.phase == .resting {
                model.pinned = false
                if model.overlay != .claude { model.overlay = .none }
            }
        }
    }

    /// Something that needs an answer (an approval, a Claude permission or question) opens the island by itself;
    /// once it's answered, an island that opened for it folds back.
    private func trackActivity() {
        let needs = withObservationTracking {
            app.needsAnswer
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackActivity() }
        }
        app.updateApprovalHotKeys()
        if needs {
            // Something to answer shows as the band, not the full notch: hover or click it to open.
            if model.phase == .resting { send(.notified) }
        } else if model.phase == .compact, app.banner == nil, !hovering {
            send(.closeRequested)
        } else if openedByItself, !context.pinned, app.claudeCard == nil {
            openedByItself = false
            if !hovering { send(.closeRequested) }
        }
        send(.contextChanged)
    }

    /// A WhatsApp reply holds the notch open; once it's sent or cleared with the pointer away, the notch folds.
    private func trackDraft() {
        let drafting = withObservationTracking { app.whatsapp.hasDraft } onChange: { [weak self] in
            Task { @MainActor in self?.trackDraft() }
        }
        if !drafting, model.expanded, !hovering, !model.pinned, !app.needsAnswer { send(.hoverLeft) }
    }

    /// Follows the remembered size; the handle writes it and the panel follows without animation.
    private func trackSize() {
        let (height, width, _, _) = withObservationTracking {
            (app.settings.notchHeight, app.settings.notchWidth, model.fittedHeight, model.usesFittedHeight)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackSize() }
        }
        let resolved = CGFloat(PanelHeights.resolve(remembered: height, defaultHeight: PanelHeights.notchDefault, screenHeight: maxHeight))
        let resolvedWidth = width > 0 ? min(max(CGFloat(width), PanelHeights.notchWidthRange.lowerBound), PanelHeights.notchWidthRange.upperBound)
            : PanelHeights.notchWidthDefault
        if resolved == model.contentHeight, resolvedWidth == model.openWidth { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.contentHeight = resolved
            model.openWidth = resolvedWidth
        }
    }

    // MARK: Resize handle

    private var maxHeight: Double { Double(model.geometry.screenFrame.height - model.geometry.notchSize.height) }

    /// One step of the drag: the panel and the content follow at once, top edge fixed, nothing animated.
    func liveResize(_ proposed: Double) {
        let height = CGFloat(PanelHeights.resolve(remembered: proposed, defaultHeight: PanelHeights.notchDefault, screenHeight: maxHeight))
        guard height != model.contentHeight, model.expanded else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.contentHeight = height }
    }

    func commitResize(_ proposed: Double) {
        app.settings.notchHeight = PanelHeights.resolve(remembered: proposed, defaultHeight: PanelHeights.notchDefault, screenHeight: maxHeight)
    }

    // MARK: Mouse

    /// The island's own rectangle inside the container; wings included.
    private var hitRect: NSRect {
        var size = model.bodySize(for: model.phase)
        size.width += 2 * model.flare(for: model.phase)
        let bounds = container.bounds
        // +2 pt above the top: the cursor parks exactly on the screen's top edge.
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height, width: size.width, height: size.height + 2)
    }

    /// Where the pointer is now: the island takes the mouse only while the pointer is over it, so the clear rest of
    /// the window never blocks the apps underneath.
    private func trackPointer() {
        guard panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let inside = hitRect.contains(NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY))
        // A drag that began on the island (the resize handle, a selection) keeps the mouse until the button is up.
        let dragging = NSEvent.pressedMouseButtons & 1 != 0 && !panel.ignoresMouseEvents
        if panel.ignoresMouseEvents == inside, !(dragging && !inside) { panel.ignoresMouseEvents = !inside }
        pointerMoved(inside: inside)
    }

    func pointerMoved(inside: Bool) {
        if inside, !hovering {
            hovering = true
            model.hovering = true
            guard model.phase != .expanded else { send(.hoverEntered); return }
            guard app.settings.openOnHover else { return }
            hoverWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovering else { return }
                self.send(.hoverEntered)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + app.settings.hoverDelay, execute: work)
        } else if !inside, hovering {
            pointerLeft()
        }
    }

    private func pointerLeft() {
        guard hovering else { return }
        hovering = false
        model.hovering = false
        hoverWork?.cancel()
        send(.hoverLeft)
    }

    func clickedInside() {
        if !model.expanded { send(.clicked) }
        panel.makeKey()
    }

    private func clickedOutside() {
        guard model.phase == .expanded, !app.needsAnswer, !model.pinned, !app.whatsapp.hasDraft else { return }
        if !hovering { close(restoringFocus: false) }
    }

    // MARK: Layout

    /// The fixed window: wide enough for the widest island, as tall as the screen, centred on the notch.
    private var fixedFrame: NSRect { model.geometry.frame(for: model.windowSize) }
}
