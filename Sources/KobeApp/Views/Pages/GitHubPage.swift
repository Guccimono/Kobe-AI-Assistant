import SwiftUI
import KobeKit

/// GitHub (spec §6.8): what needs a human first (review requests, failing default branches), then my open PRs
/// with their CI, the default branches, and the week's activity. Return opens the selected PR or branch on
/// github.com; "Ask Kobe: summarise #212" is the footer's hint (Kobe Agent reads the diff with its own tool).
struct GitHubPage: View {
    let app: AppModel
    @State private var selection = PageSelection()
    @State private var searching = false
    @State private var query = ""

    var body: some View {
        let data = app.snapshots.github?.data
        let needsYou = filter(data?.needsYou ?? [])
        let mine = filter(data?.myPRs ?? [])
        let mains = filter(data?.mains ?? [])
        // One selection across the three groups, in the order they are drawn.
        let rows = needsYou + mine + mains
        let reviews = needsYou.filter { $0.number != nil }.count
        PageScaffold(app: app, id: .github,
                     chip: reviews > 0 ? ("\(reviews) to review", .needsYou) : nil,
                     footer: footer(needsYou + mine),
                     keys: listKeys(searching: searching),
                     onKey: { key in
                         switch key {
                         case .up: selection.move(.up, count: rows.count)
                         case .down: selection.move(.down, count: rows.count)
                         case .enter: openLink(selection.current(in: rows)?.url)
                         case .search: searching = true
                         case .escape: searching = false; query = ""
                         case .refresh, .left, .right, .hide: break
                         }
                     }) {
            if let data {
                if searching {
                    PageSearchField(prompt: "Search PRs and repos", query: $query) {
                        openLink((selection.current(in: rows) ?? rows.first)?.url)
                    }
                }
                PageList(app: app, selected: selectedID(rows)) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !needsYou.isEmpty {
                            PageGroup(title: "Needs you")
                            group(needsYou, offset: 0, rows: rows, highlight: true)
                        }
                        PageGroup(title: mine.isEmpty ? "My open PRs" : "My open PRs · \(mine.count)")
                        if mine.isEmpty {
                            Text("No open PRs").font(KFont.secondary).foregroundStyle(K.text3).padding(.horizontal, 8)
                        }
                        group(mine, offset: needsYou.count, rows: rows, highlight: false)
                        if !mains.isEmpty {
                            PageGroup(title: "Default branches")
                            group(mains, offset: needsYou.count + mine.count, rows: rows, highlight: false)
                        }
                        ActivityStrip(days: data.activity, total: data.total, stars: data.stars).padding(.top, Spacing.sm)
                    }
                }
                .onChange(of: rows.count) { _, count in selection.clamp(count: count) }
            }
        } actions: {
            EmptyView()
        }
    }

    /// ⌘F: PRs by title, repo or author; branches by repo or branch.
    private func filter(_ items: [GitHubSnapshotItem]) -> [GitHubSnapshotItem] {
        guard searching else { return items }
        return items.filter { PageSearch.matches(query, [$0.title, $0.repo, $0.branch, $0.author]) }
    }

    /// Rows can repeat across groups (a failing main is also under Needs you): their scroll id is their place.
    private func selectedID(_ rows: [GitHubSnapshotItem]) -> String? {
        guard let index = selection.index, let item = selection.current(in: rows) else { return nil }
        return "\(index)-\(item.id)"
    }

    private func group(_ items: [GitHubSnapshotItem], offset: Int, rows: [GitHubSnapshotItem], highlight: Bool) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            GitHubRow(item: item, highlight: highlight, focused: selection.index == offset + index)
                .id("\(offset + index)-\(item.id)")
        }
    }

    private func footer(_ prs: [GitHubSnapshotItem]) -> [String] {
        var keys = ["↩ opens the PR", "⌘F search"]
        if let number = prs.compactMap(\.number).first { keys.append("Ask \(app.settings.copy.name): \u{201C}summarise #\(number)\u{201D}") }
        return keys
    }
}

/// A PR (number, title, repo) or a default branch (repo, branch), with its CI state. Needs-you rows are tinted
/// amber and carry their action as a button.
private struct GitHubRow: View {
    let item: GitHubSnapshotItem
    let highlight: Bool
    let focused: Bool

    var body: some View {
        let title = item.number.map { "#\($0) \(item.title)" } ?? item.repo
        let subtitle = item.number != nil
            ? [item.repo, item.author].compactMap { $0 }.joined(separator: " · ")
            : (item.branch ?? item.title)
        KitRow(title: title, subtitle: subtitle, tint: highlight ? K.amber : nil, focused: focused) {
            Circle().fill(Self.color(item.state)).frame(width: 7, height: 7)
        } trailing: {
            Text(item.state == "unknown" ? "no CI" : item.state).font(KFont.meta).foregroundStyle(Self.color(item.state))
            if highlight {
                Button(item.number != nil ? "Review" : "Open") { openLink(item.url) }.buttonStyle(GlassButtonStyle())
            }
        } action: {
            openLink(item.url)
        }
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "passing": K.green
        case "running": K.amber
        case "failing": K.red
        default: K.text3
        }
    }
}

/// The last seven days of contributions as bars, with the year's total and the stars.
private struct ActivityStrip: View {
    let days: [Int]
    let total: Int
    let stars: Int

    var body: some View {
        let top = max(days.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                PageGroup(title: "Activity · 7 days")
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, count in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(count > 0 ? K.green.opacity(0.35 + 0.65 * Double(count) / Double(top)) : K.glass)
                            .frame(width: 14, height: 4 + 22 * CGFloat(count) / CGFloat(top))
                    }
                }
                .frame(height: 26, alignment: .bottom)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("\(total) past year").font(KFont.meta).foregroundStyle(K.text3)
                Text("·").font(KFont.meta).foregroundStyle(K.text3)
                Icon(icon: .starFill, size: 10).foregroundStyle(K.text3)
                Text("\(stars)").font(KFont.meta).foregroundStyle(K.text3)
            }
        }
    }
}
