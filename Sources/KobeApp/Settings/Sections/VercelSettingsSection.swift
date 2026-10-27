import SwiftUI
import KobeKit

/// Settings › Connections › Vercel: the token, then the project filter (which projects badge the pill and
/// play a sound; the card always lists every project).
struct VercelSettingsSection: View {
    let app: AppModel

    var body: some View {
        Card(eyebrow: "Integration", title: "Vercel") {
            VStack(alignment: .leading, spacing: 0) {
                KeyRow(app: app, service: .vercel, title: "Token",
                       hint: "A Vercel access token. Kobe only reads your deployments and projects.",
                       create: Vercel.tokensPage)
                Rectangle().fill(K.hairline).frame(height: 1).padding(.vertical, 6)
                VercelProjectFilterRow(vercel: app.vercel)
            }
        }
    }
}

/// "Projects": Load list / Refresh, Clear, one checkbox per project. Empty = all.
private struct VercelProjectFilterRow: View {
    @Bindable var vercel: VercelService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: "Projects", detail: vercel.projectsMessage ?? "Notify for these projects only. None checked means all.") {
                HStack(spacing: 8) {
                    if vercel.loadingProjects {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(vercel.projects.isEmpty ? "Load list" : "Refresh") {
                            Task { await vercel.loadProjects() }
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                    if !vercel.projectFilter.isEmpty {
                        Button("Clear") { vercel.projectFilter = [] }.buttonStyle(GlassButtonStyle())
                    }
                }
            }
            if !vercel.projects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vercel.projects, id: \.self) { project in
                        Toggle(project, isOn: Binding(
                            get: { VercelProjectFilter.isChecked(project, in: vercel.projectFilter) },
                            set: { on in
                                vercel.projectFilter = VercelProjectFilter.toggled(
                                    project, on: on, filter: vercel.projectFilter, items: vercel.projects)
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(KFont.body)
                        .foregroundStyle(K.text1)
                    }
                }
                .padding(.leading, 4)
                if let footer = VercelProjectFilter.footer(filter: vercel.projectFilter, items: vercel.projects) {
                    Text(footer).font(KFont.secondary).foregroundStyle(K.text3)
                }
            }
        }
    }
}
