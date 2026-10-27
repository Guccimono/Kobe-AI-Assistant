import Foundation
import Observation
import KobeKit

/// Stripe: first poll 6 s after launch, then every 30 s, the balance, the last
/// six charges, the period's charges (the page's Today / 7 d / 30 d totals) and the next payout. A new charge after
/// the first load is reported (badge, sound, band). Read-only: GETs only.
@MainActor
@Observable
final class StripeService: ConnectionService {
    @ObservationIgnored let keys: ServiceKeys
    @ObservationIgnored let report: (ServiceEvent) -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var watcher = StripeChargeWatcher()
    /// Bumped on every key change, so a poll that started with the old key never lands.
    @ObservationIgnored private var generation = 0

    /// Newest first, at most six: the page's "Latest".
    private(set) var payments: [StripePayment] = []
    /// The charges since the start of `period` (up to 100), for its totals.
    private(set) var periodPayments: [StripePayment] = []
    /// "today", "7d" or "30d": the page's period switch.
    private(set) var period = "today"
    private(set) var nextPayout: Date?
    /// The balance the card shows (cents); it animates to each new value.
    private(set) var displayBalance = 0
    private(set) var currency = "eur"
    /// True once a poll worked (balance or charges).
    private(set) var loaded = false
    /// The last balance error, nil when fine.
    private(set) var error: String?
    private(set) var hasKey = false

    init(keys: ServiceKeys, report: @escaping (ServiceEvent) -> Void) {
        self.keys = keys
        self.report = report
        hasKey = keys.isSet(.stripe)
    }

    var pillStatus: ConnectionItem.Status {
        guard hasKey else { return .notSetUp }
        return error == nil ? .connected : .problem
    }

    var pillDetail: String { "Payments" }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func keyChanged() async -> String? {
        generation += 1
        watcher.reset()
        payments = []
        periodPayments = []
        nextPayout = nil
        displayBalance = 0
        currency = "eur"
        loaded = false
        error = nil
        hasKey = keys.isSet(.stripe)
        await poll()
        return error
    }

    /// "Refresh": poll now.
    func refresh() {
        Task { await poll() }
    }

    /// The page's period switch: the totals change at once from what is known, then a poll brings the full period.
    func setPeriod(_ period: StripePeriod) {
        guard period.rawValue != self.period else { return }
        self.period = period.rawValue
        writeSnapshot()
        refresh()
    }

    /// One tick. The key is read each time, so a key added later starts working without a restart.
    private func poll() async {
        defer { writeSnapshot() }
        let key = keys.load(.stripe)
        hasKey = key != nil
        guard let key else { return }
        let started = generation
        let client = StripeClient(key: key)
        let period = self.period
        async let balanceResult = Self.fetchBalance(client)
        async let chargesResult = client.charges(limit: 6)
        async let periodResult = client.charges(limit: 100, since: (StripePeriod(rawValue: period) ?? .today).start())
        async let payoutResult = client.nextPayout()
        let (balance, charges, inPeriod, payout) = await (balanceResult, chargesResult, periodResult, payoutResult)
        guard started == generation else { return }
        // The period changed while this poll ran: its totals belong to the old one.
        if let inPeriod, period == self.period { periodPayments = inPeriod }
        nextPayout = payout

        var newCharge: StripePayment?
        if let charges {
            newCharge = watcher.observe(charges)
            payments = Array(charges.prefix(6))
            loaded = true
        }
        switch balance {
        case .success(let value):
            error = nil
            currency = value.currency
            loaded = true
            // On a new charge the balance counts up once the new row has slid in (0.5 s).
            // Unlike a charge-only count, the balance also follows every other poll, not only new charges.
            if newCharge != nil, displayBalance != 0 {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, started == self.generation else { return }
                    self.displayBalance = value.amount
                }
            } else {
                displayBalance = value.amount
            }
        case .failure(let failure):
            error = failure.message
        }
        if let newCharge { report(StripeClient.event(for: newCharge)) }
    }

    func writeSnapshot() {
        guard hasKey else { return SnapshotWriter.write(SnapshotBuilders.notSetUp(.stripe)) }
        guard loaded || error != nil else { return }
        SnapshotWriter.write(SnapshotBuilders.stripe(balance: loaded ? StripeBalance(amount: displayBalance, currency: currency) : nil,
                                                     payments: periodPayments, period: period, error: error,
                                                     nextPayout: nextPayout, latest: payments))
    }

    private nonisolated static func fetchBalance(_ client: StripeClient) async -> Result<StripeBalance, StripeFailure> {
        do throws(StripeFailure) {
            return .success(try await client.balance())
        } catch {
            return .failure(error)
        }
    }
}
