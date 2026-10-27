import AppKit
import SwiftUI
import KobeKit

/// The first-run window: 760 × 560, dark, not resizable. Kobe is a regular app while it is open.
@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?
    private static var nav: OnboardingNav?
    private static var monitor: Any?
    private static let delegate = OnboardingWindowDelegate()

    static var isVisible: Bool { window?.isVisible == true }

    static func show(_ app: AppModel, at step: OnboardingStep? = nil) {
        let start = step ?? OnboardingMachine.resumeStep(app.settings.onboarding)
        if let nav, window != nil {
            nav.step = start
        } else {
            let nav = OnboardingNav(app: app, step: start)
            nav.closeWindow = { close() }
            self.nav = nav
            let hosting = NSHostingController(rootView: OnboardingRoot(nav: nav))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Welcome to Kobe"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)
            window.setContentSize(NSSize(width: 760, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = delegate
            self.window = window
        }
        installKeys()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    static func close() {
        window?.close()
    }

    /// ← and → move between steps while this window is key and no text field has the caret.
    private static func installKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, window.isKeyWindow, window.firstResponder as? NSText == nil,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            switch event.keyCode {
            case 123: MainActor.assumeIsolated { nav?.go(-1) }; return nil
            case 124: MainActor.assumeIsolated { if nav?.step != .ready { nav?.go(1) } }; return nil
            default: return event
            }
        }
    }

    fileprivate static func windowClosed() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // Back to a menu-bar-only app, unless Settings is still open.
        if !SettingsWindow.isVisible { NSApp.setActivationPolicy(.accessory) }
    }
}

final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { OnboardingWindow.windowClosed() }
    }
}

/// Where the person is in the eight steps, and the little state steps share (the pasted brain key, Keep it).
@MainActor
@Observable
final class OnboardingNav {
    let app: AppModel
    var step: OnboardingStep
    /// The person has answered Keep it / Change, so the default no longer applies.
    var keepDecided = false
    /// Why the brain step can't be left (the key didn't reach the Keychain).
    var saveProblem: String?
    var pastedKey = ""
    /// The door a verdict was read for; a new door or a new key starts again.
    var checkedBrain: Brain?
    @ObservationIgnored var closeWindow: () -> Void = {}

    init(app: AppModel, step: OnboardingStep) {
        self.app = app
        self.step = step
    }

    var name: String { app.settings.copy.name }

    var keyVerdict: KeyVerdict? { checkedBrain == app.settings.selectedBrain ? app.brain.verdict : nil }

    var connected: Bool {
        switch app.connect.lines[.firstHello] {
        case .done: true
        case .failed: app.connect.hello != nil
        default: false
        }
    }

    var canLeave: Bool {
        OnboardingMachine.canLeave(step, engine: app.engine.state, keyVerdict: keyVerdict,
                                   brainKeptFromHermes: app.brainKeptFromHermes && app.brain.hermesAlreadyHas != nil, connected: connected,
                                   engineElsewhere: app.settings.engineSeparateUser, engineKeySet: app.key.isSet)
    }

    /// A key that worked, or one the provider couldn't be asked about (offline): kept, checked again at step 5.
    private var keyIsWorthKeeping: Bool {
        switch keyVerdict {
        case .works?, .unreachable?: true
        default: false
        }
    }

    func go(_ delta: Int) {
        if delta > 0 {
            guard canLeave else { return }
            if step == .ready { app.finishOnboarding(); closeWindow(); return }
            guard leave() else { return }
            if let next = OnboardingMachine.next(after: step) { step = next }
        } else if let previous = OnboardingStep(rawValue: step.rawValue - 1) {
            step = previous
        }
    }

    /// Finishing a step records it; leaving the brain step keeps the key that worked in the Keychain and drops it
    /// from memory. False when the key couldn't be saved: the step stays.
    private func leave() -> Bool {
        if step == .brain {
            saveProblem = nil
            if app.brainKeptFromHermes, let had = app.brain.hermesAlreadyHas {
                app.settings.selectedBrain = had
            } else if keyIsWorthKeeping, app.settings.selectedBrain.needsKey {
                guard app.brain.store(brain: app.settings.selectedBrain, key: KeyCheck.trimmed(pastedKey)) else {
                    saveProblem = "Kobe couldn't save the key in your Keychain."
                    return false
                }
                pastedKey = ""
                checkedBrain = nil
            }
        }
        app.completeStep(step)
        return true
    }
}
