import SwiftUI
import KobeKit

/// Vercel (spec §6.9): is everything live? One row per project, its newest deployment: Ready green, building
/// amber, Error red, the rest grey; branch, commit message and age; "Visit" on the production rows. Failures come
/// first (the snapshot's order). Return opens the row's deployment.
struct VercelPage: View {
    let app: AppModel
    @State private var selection = PageSelection()
    @State private var searching = false
    @State private var query = ""

    var body: some View {
        let all = app.snapshots.vercel?.data.projects ?? []
        // ⌘F: projects by name.
        let projects = searching ? all.filter { PageSearch.matches(query, [$0.name]) } : all
        let failed = all.first { $0.state == "error" }
        PageScaffold(app: app, id: .vercel,
                     context: all.isEmpty ? nil : "\(all.count) project\(all.count == 1 ? "" : "s")",
                     footer: footer(failed),
                     keys: listKeys(searching: searching),
                     onKey: { key in
                         switch key {
                         case .up: selection.move(.up, count: projects.count)
                         case .down: selection.move(.down, count: projects.count)
                         case .enter: openLink(selection.current(in: projects)?.url)
                         case .search: searching = true
                         case .escape: searching = false; query = ""
                         case .refresh, .left, .right, .hide: break
                         }
                     }) {
            if searching {
                PageSearchField(prompt: "Search projects", query: $query) {
                    openLink((selection.current(in: projects) ?? projects.first)?.url)
                }
            }
            if projects.isEmpty {
                Text(all.isEmpty ? "No deployments yet" : "No project matches \u{201C}\(query)\u{201D}").font(KFont.body).foregroundStyle(K.text2).padding(.horizontal, 2)
            } else {
                PageList(app: app, selected: selection.current(in: projects)?.name) {
                    VStack(spacing: 2) {
                        ForEach(Array(projects.enumerated()), id: \.element.name) { index, project in
                            VercelRow(project: project, focused: selection.index == index).id(project.name)
                        }
                    }
                }
                .onChange(of: projects.count) { _, count in selection.clamp(count: count) }
            }
        } actions: {
            EmptyView()
        }
    }

    private func footer(_ failed: VercelSnapshotProject?) -> [String] {
        var keys = ["↩ opens the deployment", "⌘F search"]
        if let failed { keys.append("Ask \(app.settings.copy.name): \u{201C}why did \(failed.name) fail?\u{201D}") }
        return keys
    }
}

private struct VercelRow: View {
    let project: VercelSnapshotProject
    let focused: Bool

    var body: some View {
        let detail = [project.branch, project.commit.map { "\u{201C}\($0)\u{201D}" }, PageText.age(project.at)]
            .compactMap { $0 }.joined(separator: " · ")
        let color = Self.color(project.state)
        KitRow(title: project.name, subtitle: detail, tint: project.state == "error" ? K.red : nil, focused: focused) {
            Circle().fill(color).frame(width: 7, height: 7)
        } trailing: {
            Text(Self.label(project.state)).font(KFont.meta).foregroundStyle(color)
            if project.isProduction, project.state == "ready", project.url != nil {
                Button("Visit") { openLink(project.url) }.buttonStyle(GlassButtonStyle())
            }
        } action: {
            openLink(project.url)
        }
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "ready": K.green
        case "building", "queued", "initializing": K.amber
        case "error": K.red
        default: K.text3
        }
    }

    static func label(_ state: String) -> String {
        switch state {
        case "ready": "Ready"
        case "building", "initializing": "Building"
        case "queued": "Queued"
        case "error": "Error"
        case "canceled": "Canceled"
        default: state.capitalized
        }
    }
}
