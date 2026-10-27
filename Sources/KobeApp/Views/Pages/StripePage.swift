import SwiftUI
import KobeKit

/// Stripe (spec §6.7): money in, as a ledger. Left, the period's total and count (failed under it, refunds when
/// there are any) over the balance with pending and the next payout; right, the last transactions, failed ones in
/// red with their retry date when known. The eye (⌘H) hides every amount bank-style, "€•••", here and on Home,
/// until it is pressed again (kept in Settings). Read-only: Return or a click opens the payment in Stripe, nothing
/// here moves money. The period switch (Today / 7 d / 30 d) sits in the tab bar.
struct StripePage: View {
    let app: AppModel
    @State private var selection = PageSelection()

    var body: some View {
        let data = app.snapshots.stripe?.data
        let payments = Array((data?.payments ?? []).prefix(8))
        let hidden = app.settings.hideAmounts
        PageScaffold(app: app, id: .stripe,
                     footer: ["↩ opens in Stripe", hidden ? "⌘H shows amounts" : "⌘H hides amounts", "read-only key, nothing moves money"],
                     keys: [.up, .down, .enter, .hide],
                     onKey: { key in
                         switch key {
                         case .up: selection.move(.up, count: payments.count)
                         case .down: selection.move(.down, count: payments.count)
                         case .enter: openLink(selection.current(in: payments)?.url)
                         case .hide: app.settings.hideAmounts.toggle()
                         default: break
                         }
                     }) {
            if let data {
                HStack(alignment: .top, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        totals(data)
                        balance(data)
                    }
                    .frame(width: 236)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Spacing.sm) {
                            PageGroup(title: "Last transactions")
                            Spacer(minLength: 0)
                            KitIconButton(icon: hidden ? .eyeSlash : .eye,
                                          help: hidden ? "Show amounts (⌘H)" : "Hide amounts (⌘H)") {
                                app.settings.hideAmounts.toggle()
                            }
                        }
                        if payments.isEmpty {
                            Text("No payments yet").font(KFont.body).foregroundStyle(K.text2).padding(.horizontal, 2)
                        } else {
                            ForEach(Array(payments.enumerated()), id: \.element.id) { index, payment in
                                StripePaymentRow(app: app, payment: payment, focused: selection.index == index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: payments.count) { _, count in selection.clamp(count: count) }
            }
        } actions: {
            EmptyView()
        }
    }

    private func totals(_ data: StripeSnapshotData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            KPI(label: Self.periodName(data.period), value: app.money(data.total, data.currency),
                delta: "\(data.count) payment\(data.count == 1 ? "" : "s")")
            // The shim doesn't fetch refunds (it always writes 0): a count shows only when there is one.
            Text("\(data.failed) failed" + (data.refunds > 0 ? " · \(data.refunds) refund\(data.refunds == 1 ? "" : "s")" : ""))
                .font(KFont.meta).foregroundStyle(data.failed > 0 ? K.red : K.text3)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
    }

    private func balance(_ data: StripeSnapshotData) -> some View {
        var under: [String] = []
        if data.pending > 0 { under.append("\(app.money(data.pending, data.currency)) pending") }
        if let payout = data.nextPayout { under.append("next payout \(PageText.day(payout))") }
        return VStack(alignment: .leading, spacing: 4) {
            // `available` is available + pending together until the snapshot splits them, so no "available" here.
            KPI(label: "Balance", value: app.money(data.available, data.currency), delta: nil)
            Text(under.isEmpty ? " " : under.joined(separator: " · ")).font(KFont.meta).foregroundStyle(K.text3)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.tab, style: .continuous))
    }

    static func periodName(_ period: String) -> String {
        switch period {
        case "7d": "7 days"
        case "30d": "30 days"
        default: "Today"
        }
    }
}

/// One payment: the customer, the plan when known (or, failed, "failed · retry Fri" in red), the amount and when.
private struct StripePaymentRow: View {
    let app: AppModel
    let payment: StripeSnapshotPayment
    let focused: Bool

    var body: some View {
        let failed = payment.status == "failed"
        let amount = app.money(payment.amount, payment.currency)
        KitRow(title: payment.customer.isEmpty ? "Payment" : payment.customer, detail: detail(failed: failed),
               meta: nil, tint: failed ? K.red : nil, focused: focused) {
            Circle().fill(failed ? K.red : StripLayout.tint(.stripe).color).frame(width: 6, height: 6)
        } trailing: {
            Text(failed ? amount : "+" + amount).font(KFont.row).monospacedDigit()
                .foregroundStyle(failed ? K.red : K.green)
            Text(PageText.when(payment.at)).font(KFont.meta).foregroundStyle(K.text3).monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
        } action: {
            openLink(payment.url)
        }
    }

    /// nil when there is nothing to say (no plan, not failed): no empty line. A failed payment without a retry
    /// date says "failed" only.
    private func detail(failed: Bool) -> Text? {
        guard failed else { return payment.plan.flatMap { $0.isEmpty ? nil : Text(verbatim: $0) } }
        let retry = payment.retryAt.map { " · retry \(PageText.day($0))" } ?? ""
        return Text(verbatim: "failed\(retry)").foregroundStyle(K.red)
    }
}
