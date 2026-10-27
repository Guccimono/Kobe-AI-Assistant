import AppKit
import SwiftUI
import KobeKit

/// Settings › Connections › On this Mac: Mail, Calendar, Reminders and Notes. Each is off until its switch goes
/// on, and only that click asks macOS for access.
struct MacSettingsSection: View {
    let app: AppModel

    var body: some View {
        Card(eyebrow: "On this Mac", title: "Mail, Calendar, Reminders, Notes") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(MacKind.allCases, id: \.self) { kind in row(kind) }
                Text("These stay on this Mac. Kobe writes what it shows to the folder Kobe Agent reads.")
                    .font(KFont.secondary).foregroundStyle(K.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ kind: MacKind) -> some View {
        let mac = app.mac
        let on = app.settings.isOn(kind)
        let access = mac.access(kind)
        let running = mac.appRunning(kind)
        let status = MacConnectionCopy.status(kind, on: on, access: access, running: running, problem: mac.problem[kind])
        return VStack(alignment: .leading, spacing: 6) {
            ListRow(icon: StripLayout.icon(kind.id), title: StripLayout.name(kind.id), subtitle: status) {
                Toggle("", isOn: Binding(get: { app.settings.isOn(kind) }, set: { set(kind, $0) }))
                    .toggleStyle(.switch).labelsHidden().tint(K.lime)
            }
            if on, access == .denied {
                Button("Open System Settings") { openPrivacy(kind) }.buttonStyle(GlassButtonStyle())
            } else if on, kind.bundleID != nil, access != .granted {
                Button("Finish setup") { Task { await mac.turnedOn(kind) } }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(!running)
            }
        }
    }

    private func set(_ kind: MacKind, _ on: Bool) {
        app.settings.setOn(kind, on)
        if on { Task { await app.mac.turnedOn(kind) } } else { app.mac.turnedOff(kind) }
    }

    private func openPrivacy(_ kind: MacKind) {
        let pane = switch kind {
        case .agenda: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .mail, .notes: "Privacy_Automation"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
