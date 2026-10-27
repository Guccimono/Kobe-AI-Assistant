import SwiftUI
import KobeKit

/// Google (spec §6.6, mockup 03 headline A): The business's presence over the last 7 days against the 7 before. Four
/// KPIs (Analytics visitors, Search clicks, average position, Business Profile calls), each opening its Google
/// report; top queries with a 7-bar sparkline of daily clicks; the Business Profile box, waiting for Google's API
/// access until plan 2c. Kobe Agent writes it; the app never holds Google credentials.
struct GooglePage: View {
    let app: AppModel
    @State private var selection = PageSelection()

    var body: some View {
        let snapshot = app.snapshots.google
        let queries = snapshot?.data.topQueries ?? []
        let site = snapshot.flatMap { GoogleFormat.site(searchURL: $0.data.reportUrls.search) }
        PageScaffold(app: app, id: .google,
                     context: site.map { "\($0) · last 7 days vs previous" },
                     footer: ["↩ opens the report", "read-only Google access"],
                     onKey: { key in
                         switch key {
                         case .up: selection.move(.up, count: queries.count)
                         case .down: selection.move(.down, count: queries.count)
                         case .enter: openLink(snapshot?.data.reportUrls.search)
                         default: break
                         }
                     }) {
            if let data = snapshot?.data {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        tile("Analytics · visitors", GoogleFormat.count(data.visitors),
                             GoogleFormat.deltaPercent(data.visitors, data.visitorsPrev), url: data.reportUrls.analytics)
                        tile("Search · clicks", GoogleFormat.count(data.clicks),
                             GoogleFormat.deltaPercent(data.clicks, data.clicksPrev), url: data.reportUrls.search)
                        tile("Search · position", GoogleFormat.position(data.position),
                             GoogleFormat.positionDelta(data.position, data.positionPrev), url: data.reportUrls.search)
                        tile("Profile · calls", GoogleFormat.calls(data.calls),
                             data.calls.flatMap { now in data.callsPrev.flatMap { GoogleFormat.deltaPercent(now, $0) } },
                             url: nil)
                    }
                    HStack(alignment: .top, spacing: Spacing.md) {
                        topQueries(data).frame(maxWidth: .infinity, alignment: .leading)
                        businessProfile(data).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onChange(of: queries.count) { _, count in selection.clamp(count: count) }
            }
        } actions: {
            EmptyView()
        }
    }

    /// A KPI in a glass tile; a click opens its report.
    private func tile(_ label: String, _ value: String, _ delta: GoogleFormat.Delta?, url: String?) -> some View {
        Button { openLink(url) } label: {
            KPI(label: label, value: value, delta: delta?.text, deltaUp: delta?.good)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .help(url == nil ? "" : "Open in Google")
    }

    private func topQueries(_ data: GoogleSnapshotData) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom) {
                PageGroup(title: "Top queries")
                Spacer(minLength: Spacing.sm)
                Sparkline(values: data.dailyClicks, tint: StripLayout.tint(.google).color)
                    .frame(width: 84, height: 22)
                    .help("Clicks per day, last 7 days")
            }
            if data.topQueries.isEmpty {
                Text("No searches yet").font(KFont.body).foregroundStyle(K.text2).padding(.horizontal, 2)
            }
            ForEach(Array(data.topQueries.enumerated()), id: \.offset) { index, query in
                KitRow(title: query.query, detail: nil, meta: nil, tint: nil, focused: selection.index == index) {
                    Circle().fill(StripLayout.tint(.google).color).frame(width: 6, height: 6)
                } trailing: {
                    Text(GoogleFormat.count(query.clicks)).font(KFont.row).monospacedDigit().foregroundStyle(K.text1)
                } action: {
                    openLink(data.reportUrls.search)
                }
            }
        }
    }

    private func businessProfile(_ data: GoogleSnapshotData) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            PageGroup(title: "Business Profile")
            Text(data.businessProfile == "waiting_access" ? "Waiting for Google's API access" : "Arrives with Kobe Agent's next update")
                .font(KFont.body).foregroundStyle(K.text2)
            Text("Reviews, calls and questions show here once Google grants it.")
                .font(KFont.meta).foregroundStyle(K.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
    }
}

/// Seven bars, oldest left, scaled to the busiest day; an empty day is a 2 pt stub so the week still reads.
private struct Sparkline: View {
    let values: [Int]
    let tint: Color

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tint.opacity(value == 0 ? 0.3 : 0.9))
                        .frame(height: max(2, geo.size.height * CGFloat(value) / CGFloat(top)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
