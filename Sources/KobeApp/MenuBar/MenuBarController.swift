import AppKit
import KobeKit

/// The Kobe icon in the menu bar. Left click: Settings (brought to the front if already open). Right click: a menu
/// with the everyday actions. The icon says what waits: an approval first, then keep awake, else Kobe's mark.
@MainActor
final class MenuBarController: NSObject {
    private let app: AppModel
    private var statusItem: NSStatusItem?

    init(app: AppModel) {
        self.app = app
        super.init()
        track()
    }

    private func track() {
        let (show, needs, awake) = withObservationTracking {
            (app.settings.showMenuBar, app.needsAnswer, app.keepAwake.isActive)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(iconClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.toolTip = "Kobe: click for Settings, right-click for actions"
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        let icon: PhosphorIcon = needs ? .warningCircleFill : awake ? .sunFill : .sparkleFill
        if let image = Icon.image(icon)?.copy() as? NSImage {
            image.size = NSSize(width: 16, height: 16)
            image.isTemplate = true
            statusItem?.button?.image = image
        }
    }

    @objc private func iconClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            SettingsWindow.show(app)
        }
    }

    // MARK: Right-click menu

    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.addItem(action("Open Kobe", #selector(openHome)))
        menu.addItem(action("New chat", #selector(newChat)))
        let quick = action("Quick ask", #selector(quickAsk))
        quick.keyEquivalent = " "
        quick.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(quick)
        menu.addItem(action("Drop files…", #selector(openDrop)))
        menu.addItem(.separator())

        let awake = NSMenuItem(title: app.keepAwake.isActive ? "Keep awake · \(app.keepAwake.shortText)" : "Keep awake", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let off = action("Off", #selector(keepAwakeChosen(_:)))
        off.tag = -1
        off.state = app.keepAwake.isActive ? .off : .on
        sub.addItem(off)
        for minutes in KeepAwake.choices {
            let entry = action(KeepAwake.label(minutes: minutes), #selector(keepAwakeChosen(_:)))
            entry.tag = minutes
            sub.addItem(entry)
        }
        awake.submenu = sub
        menu.addItem(awake)
        menu.addItem(.separator())
        let settings = action("Settings…", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(action("Quit Kobe", #selector(quit)))

        item.menu = menu
        item.button?.performClick(nil)  // shows the menu under the icon
        item.menu = nil  // back to click-for-Settings
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openHome() { app.show(.home) }
    @objc private func newChat() { app.newChat() }
    @objc private func quickAsk() { app.showOverlay(.quickAsk) }
    @objc private func openDrop() { app.goHome(focusComposer: true) }
    @objc private func openSettings() { SettingsWindow.show(app) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func keepAwakeChosen(_ sender: NSMenuItem) {
        app.setKeepAwake(minutes: sender.tag < 0 ? nil : sender.tag)
    }
}
