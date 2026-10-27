import AppKit
import KobeKit

/// The app's entry point, called by `Sources/KobeMain/main.swift` (the `Kobe` executable).
@MainActor
public enum KobeApp {
    public static func run() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = EditMenu.mainMenu()
        app.run()
        _ = delegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopConnections()
        model?.voice.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --demo: in-memory secrets (Kobe's key, the services', WhatsApp's) and no Claude socket, so checks and
        // screenshots never touch the Keychain.
        let demo = CommandLine.arguments.contains("--demo")
        // --demo also writes and reads its snapshots in a fresh temp folder, never the real exchange folder. Set
        // before anything reads `SnapshotFolder.root`.
        if demo {
            let exchange = FileManager.default.temporaryDirectory.appendingPathComponent("kobe-demo-exchange")
            try? FileManager.default.removeItem(at: exchange)
            setenv("KOBE_EXCHANGE_ROOT", exchange.path, 1)
        }
        // --demo reads made-up Mail, Calendar, Reminders and Notes, never the real ones.
        let model = demo ? AppModel(secrets: InMemorySecrets(), demoMac: true, shell: DemoShell()) : AppModel()
        model.controller = IslandController(app: model)
        model.menuBar = MenuBarController(app: model)
        self.model = model
        model.start(claude: !demo || CommandLine.arguments.contains("--claude"))
        handleLaunchFlags(model)
        if !demo, model.onboardingShouldOpen { OnboardingWindow.show(model) }
    }

    /// `--open home|chat|onboarding|drop|quick|page-<id>|gear|settings|settings-claude|settings-engine|settings-brain|settings-assistant` opens a view right away (for screenshots and checks).
    private func handleLaunchFlags(_ model: AppModel) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--open"), index + 1 < args.count else { return }
        switch args[index + 1] {
        case "home": model.show(.home)
        case "chat": model.show(.home)
        case "drop": model.goHome(focusComposer: true)
        case "quick": model.showOverlay(.quickAsk)
        case let view where view.hasPrefix("page-"):
            guard let id = WidgetID(rawValue: String(view.dropFirst(5))) else { return }
            model.openPage(id)
        case "onboarding": OnboardingWindow.show(model, at: .welcome); return
        case "gear": SettingsWindow.show(model); return
        case "settings": SettingsWindow.show(model); return
        case "settings-claude": SettingsWindow.show(model, page: .claude); return
        case "settings-engine", "settings-server": SettingsWindow.show(model, page: .engine); return
        case "settings-brain": SettingsWindow.show(model, page: .brain); return
        case "settings-assistant": SettingsWindow.show(model, page: .assistant); return
        default: break
        }
        model.island.pinned = true
    }
}
