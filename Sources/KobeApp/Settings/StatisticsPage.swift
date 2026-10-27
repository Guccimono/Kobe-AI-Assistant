import SwiftUI
import KobeKit

/// Statistics: a hero card with the period switch, four numbers, messages per day, where you talk,
/// then the models with their tokens and cost, and how much ran in the cloud, free, or on this Mac. Counted on this
/// Mac from Hermes' chat list; the cost is Hermes' own (the provider's charge when known, else its estimate).
struct StatisticsPage: View {
    let app: AppModel
    @State private var period: Statistics.Period = .month
    @State private var sessions: [HermesSession] = []

    var body: some View {
        let stats = Statistics.compute(sessions: sessions, period: period, copy: app.settings.copy)
        VStack(alignment: .leading, spacing: 16) {
            hero
            HStack(spacing: 16) {
                tile("Chats", "\(stats.chats)", nil)
                tile("Messages", "\(stats.messages)", "\(stats.toolCalls) things \(app.settings.copy.name) did")
                tile("Tokens", Self.compact(stats.tokens),
                     stats.cachedTokens > 0 ? "in and out, plus \(Self.compact(stats.cachedTokens)) cached" : "in and out")
                tile("Cost", Statistics.dollars(stats.costUsd),
                     stats.unpricedChats > 0 ? "\(stats.unpricedChats) chats not priced" : "as charged or estimated")
            }
            HStack(alignment: .top, spacing: 16) {
                Card(title: "Messages per day") { DayBars(days: stats.perDay) }
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                Card(title: "Where you talk") {
                    ShareBars(shares: stats.bySource)
                }
                .frame(width: 320)
            }
            HStack(alignment: .top, spacing: 16) {
                Card(title: "Models") { ModelTable(models: stats.byModel) }
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                Card(title: "Cloud or this Mac") { ShareBars(shares: stats.byPlace, unit: "of tokens") }
                    .frame(width: 320)
            }
            Text("Counted on your Mac, never sent anywhere.").font(.system(size: 13)).foregroundStyle(K.text3)
        }
        .task { sessions = (try? await app.client.listSessions(limit: 200)) ?? app.chats.sessions }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Statistics").font(.system(size: 38, weight: .bold)).tracking(-0.8).foregroundStyle(K.text1)
            Text("Your chats with \(app.settings.copy.name), how much, and where.").font(.system(size: 16)).foregroundStyle(K.text2)
            Segmented(options: Statistics.Period.allCases.map(\.rawValue),
                      selected: Statistics.Period.allCases.firstIndex(of: period) ?? 1) { period = Statistics.Period.allCases[$0] }
                .padding(4)
                .background(Color.black.opacity(0.35), in: Capsule())
                .padding(.top, 14)
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RadialGradient(colors: [K.green.opacity(0.28), .clear], center: .topTrailing, startRadius: 0, endRadius: 520),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(K.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func tile(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14)).foregroundStyle(K.text2)
            Text(value).font(.system(size: 44, weight: .bold)).tracking(-1.5).foregroundStyle(K.text1)
            Text(detail ?? " ").font(.system(size: 13)).foregroundStyle(K.text3)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(K.panel, radius: 22)
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1000: "\(n)"
        case ..<1_000_000: String(format: "%.1fk", Double(n) / 1000)
        default: String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}

/// One bar per day; the last day is labelled bold. A dashed baseline marks days with nothing.
struct DayBars: View {
    let days: [Statistics.Day]

    var body: some View {
        let top = max(1, days.map(\.messages).max() ?? 1)
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: days.count > 40 ? 2 : 6) {
                ForEach(days.indices, id: \.self) { index in
                    let value = days[index].messages
                    VStack {
                        Spacer(minLength: 0)
                        if value > 0 {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(K.lime)
                                .frame(height: max(6, 220 * CGFloat(value) / CGFloat(top)))
                        } else {
                            Rectangle().fill(K.panel3).frame(height: 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(days[index].start.formatted(date: .abbreviated, time: .omitted)): \(value) messages")
                }
            }
            .frame(height: 230)
            HStack {
                ForEach(labels, id: \.offset) { label in
                    Text(label.text).font(.system(size: 12, weight: label.offset == days.count - 1 ? .bold : .regular))
                        .foregroundStyle(label.offset == days.count - 1 ? K.text1 : K.text3)
                    if label.offset != days.count - 1 { Spacer() }
                }
            }
        }
    }

    /// About six date labels under the bars, always including today.
    private var labels: [(offset: Int, text: String)] {
        guard !days.isEmpty else { return [] }
        let step = max(1, days.count / 6)
        var offsets = Array(stride(from: 0, to: days.count - 1, by: step))
        offsets.append(days.count - 1)
        return offsets.map { ($0, days[$0].start.formatted(.dateTime.day())) }
    }
}

/// Labelled bars, largest first: where you talk, or where the models ran.
private struct ShareBars: View {
    let shares: [Statistics.Share]
    var unit = ""

    var body: some View {
        if shares.isEmpty {
            Text("Nothing yet.").font(.system(size: 14)).foregroundStyle(K.text3)
        }
        ForEach(shares, id: \.label) { share in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(share.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(K.text1)
                    Spacer()
                    Text("\(Int((share.share * 100).rounded())) %" + (unit.isEmpty ? "" : " \(unit)"))
                        .font(.system(size: 14)).foregroundStyle(K.text2)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(K.panel3)
                        Capsule().fill(K.lime).frame(width: max(6, proxy.size.width * share.share))
                    }
                }
                .frame(height: 6)
            }
            .padding(.bottom, 14)
        }
    }
}

/// One row per model: its name (provider dimmed), where it runs, chats, tokens and cost.
private struct ModelTable: View {
    let models: [Statistics.ModelUsage]

    var body: some View {
        if models.isEmpty {
            Text("Nothing yet.").font(.system(size: 14)).foregroundStyle(K.text3)
        }
        VStack(spacing: 0) {
            ForEach(models, id: \.model) { usage in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.name(usage.model)).font(.system(size: 15, weight: .semibold)).foregroundStyle(K.text1)
                            .lineLimit(1).truncationMode(.middle)
                        Text(Self.provider(usage.model) + usage.place.label + " · \(usage.chats) chats")
                            .font(.system(size: 13)).foregroundStyle(K.text3).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(Statistics.dollars(usage.costUsd)).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(usage.costUsd > 0 ? K.text1 : K.text2)
                        Text(StatisticsPage.compact(usage.tokens) + " tokens"
                             + (usage.cachedTokens > 0 ? " + \(StatisticsPage.compact(usage.cachedTokens)) cached" : ""))
                            .font(.system(size: 13)).foregroundStyle(K.text3)
                    }
                }
                .padding(.vertical, 10)
                if usage.model != models.last?.model { Rectangle().fill(K.panel3).frame(height: 1) }
            }
        }
    }

    /// "nemotron-3-ultra-550b-a55b" from "nvidia/nemotron-3-ultra-550b-a55b:free".
    static func name(_ model: String) -> String {
        let last = model.split(separator: "/").last.map(String.init) ?? model
        return last.hasSuffix(":free") ? String(last.dropLast(5)) : last
    }

    /// "nvidia · " from "nvidia/…"; nothing without a provider.
    static func provider(_ model: String) -> String {
        let parts = model.split(separator: "/")
        return parts.count > 1 ? "\(parts[0]) · " : ""
    }
}
