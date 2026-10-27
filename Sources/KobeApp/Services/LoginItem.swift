import ServiceManagement

/// Open Kobe at login (Settings › General), through the system's login items.
enum LoginItem {
    static func set(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled { try service.register() }
            if !enabled, service.status == .enabled { try service.unregister() }
        } catch {
            // Running from a build folder can't register; the installed app can.
        }
    }
}
