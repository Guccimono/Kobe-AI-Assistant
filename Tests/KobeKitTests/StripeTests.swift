import Foundation
import Testing
@testable import KobeKit

// Stripe: balance + last three charges, read-only.

@Test func stripeBalanceSumsAvailableAndPending() async throws {
    let (session, host, base) = stubbed(["/v1/balance": "stripe_balance.json"])
    let client = StripeClient(key: "rk_test_abc", base: base, session: session)
    let balance = try await client.balance()
    #expect(balance == StripeBalance(amount: 128_450, currency: "eur"))

    let request = try #require(StubURLProtocol.requests(host).first)
    #expect(request.url?.path == "/v1/balance")
    #expect(request.httpMethod == "GET")
    #expect(request.timeoutInterval == 10)
    let expected = "Basic " + Data("rk_test_abc:".utf8).base64EncodedString()
    #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
}

@Test func stripeDefaultsToEurosWhenNoBucket() {
    let balance = StripeClient.parseBalance(Data(#"{"available":[],"pending":[]}"#.utf8))
    #expect(balance == StripeBalance(amount: 0, currency: "eur"))
    #expect(StripeClient.parseBalance(Data("nope".utf8)) == nil)
}

@Test func stripeChargesParseFields() async throws {
    let (session, host, base) = stubbed(["/v1/charges": "stripe_charges.json"])
    let client = StripeClient(key: "rk_test_abc", base: base, session: session)
    let charges = try #require(await client.charges())
    #expect(charges.map(\.id) == ["ch_1", "ch_2", "ch_3"])
    // description, else the billing name, else nothing
    #expect(charges.map(\.description) == ["Sarah L.", "Pro plan", nil])
    #expect(charges[0].amount == 4900)
    #expect(charges[0].currency == "eur")
    #expect(charges[0].createdAt == Date(timeIntervalSince1970: 1_792_600_000))
    #expect(charges[0].isSuccess)
    #expect(!charges[2].isSuccess)
    #expect(charges[0].amountFormatted == "49.00")

    let request = try #require(StubURLProtocol.requests(host).first)
    #expect(request.url?.query == "limit=3")
}

@Test func stripeChargesErrorsAreIgnored() async {
    let (session, _, base) = stubbed(["/v1/charges": "error_401.json"], status: 401)
    let client = StripeClient(key: "rk", base: base, session: session)
    #expect(await client.charges() == nil)
}

@Test func stripeBalanceErrorsHaveMessages() async {
    for (status, message) in [
        (401, "Invalid API key (401)"),
        (403, "This key can't read the balance: give the restricted key read access to Balance and Charges."),
        (500, "API error 500"),
    ] {
        let (session, _, base) = stubbed(["/v1/balance": "error_401.json"], status: status)
        let client = StripeClient(key: "rk", base: base, session: session)
        await #expect(throws: StripeFailure(message: message)) { try await client.balance() }
    }
}

@Test func stripeOfflineSaysNoConnection() async {
    let stub = StubURLProtocol.make { _ in .init(error: URLError(.notConnectedToInternet)) }
    let client = StripeClient(key: "rk", base: stub.base, session: stub.session)
    do {
        _ = try await client.balance()
        Issue.record("expected a failure")
    } catch {
        #expect(!error.message.isEmpty)
        #expect(error.message != "API error 0")
    }
    #expect(StripeClient.message(status: 0, error: nil) == "No connection")
}

@Test func stripeTimeAgoIsShort() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func ago(_ seconds: TimeInterval) -> String {
        StripePayment(id: "c", amount: 1, currency: "eur", description: nil,
                      createdAt: now.addingTimeInterval(-seconds), status: "succeeded").timeAgo(now: now)
    }
    #expect(ago(10) == "just now")
    #expect(ago(59) == "just now")
    #expect(ago(60) == "1m")
    #expect(ago(3599) == "59m")
    #expect(ago(3600) == "1h")
    #expect(ago(86_399) == "23h")
    #expect(ago(86_400 * 3) == "3d")
}

@Test func stripeAmountFormatting() {
    let p = StripePayment(id: "c", amount: 123_456, currency: "usd", description: nil, createdAt: .now, status: "x")
    #expect(p.amountFormatted == "1234.56")
    #expect(StripeBalance(amount: 5, currency: "eur").formatted == "0.05")
}

private func charge(_ id: String, status: String = "succeeded", description: String? = "Pro plan") -> StripePayment {
    StripePayment(id: id, amount: 4900, currency: "eur", description: description, createdAt: .now, status: status)
}

@Test func stripeFirstLoadIsSilentThenNewChargesReport() {
    var watcher = StripeChargeWatcher()
    #expect(watcher.observe([charge("ch_1"), charge("ch_0")]) == nil)
    #expect(watcher.observe([charge("ch_1"), charge("ch_0")]) == nil)
    #expect(watcher.observe([charge("ch_2"), charge("ch_1")])?.id == "ch_2")
    #expect(watcher.observe([charge("ch_2"), charge("ch_1")]) == nil)
}

@Test func stripeFirstChargeOnAnEmptyAccountReports() {
    var watcher = StripeChargeWatcher()
    #expect(watcher.observe([]) == nil)
    #expect(watcher.observe([charge("ch_1")])?.id == "ch_1")
}

@Test func stripeWatcherResetMakesTheNextLoadSilent() {
    var watcher = StripeChargeWatcher()
    _ = watcher.observe([charge("ch_1")])
    watcher.reset()
    #expect(watcher.observe([charge("ch_9")]) == nil)
}

@Test func stripeEventForSucceededAndFailedCharges() {
    let ok = StripeClient.event(for: charge("ch_1"))
    #expect(ok == ServiceEvent(pill: "stripe", kind: .finished, detail: "+49.00 EUR · Pro plan", sound: .finish))
    let failed = StripeClient.event(for: charge("ch_2", status: "failed", description: nil))
    #expect(failed == ServiceEvent(pill: "stripe", kind: .error, detail: "+49.00 EUR", sound: .error))
}

// The next payout: the newest payout, while it is still on its way.

@Test func payoutsParsed() async throws {
    let (session, host, base) = stubbed(["/v1/payouts": "stripe_payouts.json"])
    let client = StripeClient(key: "rk_test_abc", base: base, session: session)
    let next = await client.nextPayout()
    #expect(next == Date(timeIntervalSince1970: 1_793_059_200))
    let request = try #require(StubURLProtocol.requests(host).first)
    #expect(request.url?.query == "limit=1")

    // Already paid: there is no next one to show yet.
    let paid = Data(#"{"data":[{"id":"po_0","arrival_date":1792000000,"status":"paid"}]}"#.utf8)
    #expect(StripeClient.parseNextPayout(paid) == nil)
    #expect(StripeClient.parseNextPayout(Data(#"{"data":[]}"#.utf8)) == nil)
    #expect(StripeClient.parseNextPayout(Data("nope".utf8)) == nil)
}

@Test func payoutsErrorsAreIgnored() async {
    let (session, _, base) = stubbed(["/v1/payouts": "error_401.json"], status: 403)
    let client = StripeClient(key: "rk", base: base, session: session)
    #expect(await client.nextPayout() == nil)
}

@Test func stripeBuilderCarriesTheNextPayoutAndTheLatestList() {
    let now = Date(timeIntervalSince1970: 1_792_765_690)
    let payout = Date(timeIntervalSince1970: 1_793_059_200)
    let old = StripePayment(id: "ch_old", amount: 900, currency: "eur", description: "Old", createdAt: now.addingTimeInterval(-3 * 86_400), status: "succeeded")
    let today = StripePayment(id: "ch_new", amount: 4900, currency: "eur", description: "New", createdAt: now.addingTimeInterval(-60), status: "succeeded")
    let s = SnapshotBuilders.stripe(balance: StripeBalance(amount: 100, currency: "eur"), payments: [today, old],
                                    period: "today", error: nil, nextPayout: payout, latest: [today, old], now: now)
    #expect(s.data.nextPayout == payout)
    #expect(s.data.total == 4900 && s.data.count == 1)
    #expect(s.data.payments.map(\.id) == ["ch_new", "ch_old"])
}
