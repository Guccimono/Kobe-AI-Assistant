import Foundation
import Testing
@testable import KobeKit

// MARK: - Parsing

@Test func vercelKeepsOnlyTerminalDeploymentsInOrder() async throws {
    let (session, _, base) = stubbed(["/v6/deployments": "vercel_deployments.json"])
    let list = try await VercelClient(token: "tok", session: session, base: base).deployments()
    #expect(list.map(\.id) == ["d1", "d2"])
    let first = list[0]
    #expect(first.projectName == "menuly-web")
    #expect(first.url == "menuly-web-abc.vercel.app")
    #expect(first.state == "READY")
    #expect(first.commitMessage == "Fix menu prices")
    #expect(first.branch == "main")
    // This fixture only has `created`: it stands in for `createdAt`.
    #expect(first.createdAt == Date(timeIntervalSince1970: 1_792_600_000))
}

@Test func vercelReadsGitLabAndBitbucketMetaAndPrefersCreatedAt() throws {
    let json = try JSONSerialization.jsonObject(with: StubURLProtocol.fixture("vercel_deployments_mixed.json"))
    let list = Vercel.parseDeployments(json)
    #expect(list.map(\.id) == ["g1", "b1", "n1"])
    #expect(list[0].commitMessage == "Try new header" && list[0].branch == "header")
    #expect(list[0].createdAt == Date(timeIntervalSince1970: 1_792_600_000))
    #expect(list[1].commitMessage == "Typos" && list[1].branch == "fix/typos")
    #expect(list[2].url == "" && list[2].commitMessage == nil && list[2].branch == nil)
    #expect(list[2].createdAt == Date(timeIntervalSince1970: 0))
}

@Test func vercelParsingToleratesJunk() {
    #expect(Vercel.parseDeployments(["nope": 1]).isEmpty)
    #expect(Vercel.parseDeployments([1, 2]).isEmpty)
    #expect(Vercel.parseProjectNames(["projects": "x"]).isEmpty)
}

// MARK: - Labels

@Test func vercelStatusLabels() {
    func make(_ state: String) -> VercelDeployment {
        VercelDeployment(id: "x", projectName: "p", url: "u", state: state, createdAt: .now, commitMessage: nil, branch: nil)
    }
    #expect(make("READY").isSuccess && make("READY").statusLabel == "Ready")
    #expect(!make("CANCELED").isSuccess && make("CANCELED").statusLabel == "Canceled")
    #expect(!make("ERROR").isSuccess && make("ERROR").statusLabel == "Error")
}

@Test func vercelTimeAgoIsShort() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func ago(_ seconds: TimeInterval) -> String { Vercel.timeAgo(now.addingTimeInterval(-seconds), now: now) }
    #expect(ago(0) == "just now")
    #expect(ago(59) == "just now")
    #expect(ago(60) == "1m")
    #expect(ago(3599) == "59m")
    #expect(ago(3600) == "1h")
    #expect(ago(86_399) == "23h")
    #expect(ago(86_400) == "1d")
    #expect(ago(10 * 86_400) == "10d")
    #expect(Vercel.agoPhrase(now, now: now) == "just now")
    #expect(Vercel.agoPhrase(now.addingTimeInterval(-120), now: now) == "2m ago")
}

// MARK: - Requests

@Test func vercelSendsBearerTokenAndQueries() async throws {
    let (session, host, base) = stubbed(["/v6/deployments": "vercel_deployments.json", "/v9/projects": "vercel_projects.json"])
    let client = VercelClient(token: "secret-token", session: session, base: base)
    _ = try await client.deployments()
    _ = try await client.projects()
    let requests = StubURLProtocol.requests(host)
    #expect(requests.count == 2)
    #expect(requests[0].url?.path == "/v6/deployments" && requests[0].url?.query == "limit=5")
    #expect(requests[1].url?.path == "/v9/projects" && requests[1].url?.query == "limit=100")
    for request in requests {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 10)
    }
    #expect(VercelClient.defaultBase == URL(string: "https://api.vercel.com")!)
}

@Test func vercelProjectNamesAreSorted() async throws {
    let (session, _, base) = stubbed(["/v9/projects": "vercel_projects.json"])
    let names = try await VercelClient(token: "t", session: session, base: base).projects()
    #expect(names == ["docs-site", "menuly-web", "old-landing"])
    let (emptySession, _, emptyBase) = stubbed(["/v9/projects": "vercel_projects_empty.json"])
    #expect(try await VercelClient(token: "t", session: emptySession, base: emptyBase).projects().isEmpty)
}

@Test func vercelMapsHTTPFailures() async {
    let (refused, _, refusedBase) = stubbed(["/v6/deployments": "error_401.json"], status: 401)
    await #expect(throws: ServiceError.badKey) {
        try await VercelClient(token: "t", session: refused, base: refusedBase).deployments()
    }
    let (broken, _, brokenBase) = stubbed(["/v6/deployments": "error_401.json"], status: 500)
    await #expect(throws: ServiceError.failed("HTTP 500")) {
        try await VercelClient(token: "t", session: broken, base: brokenBase).deployments()
    }
    let offline = StubURLProtocol.make { _ in .init(error: URLError(.notConnectedToInternet)) }
    await #expect(throws: ServiceError.offline) {
        try await VercelClient(token: "t", session: offline.session, base: offline.base).projects()
    }
}

// MARK: - Filter

private func deployment(_ id: String, _ project: String, _ state: String = "READY") -> VercelDeployment {
    VercelDeployment(id: id, projectName: project, url: "\(id).vercel.app", state: state,
                     createdAt: .now, commitMessage: nil, branch: nil)
}

@Test func vercelEmptyFilterWatchesEveryProject() {
    let list = [deployment("1", "a"), deployment("2", "b")]
    #expect(Vercel.filtered(list, by: []).map(\.id) == ["1", "2"])
    #expect(Vercel.filtered(list, by: ["b"]).map(\.id) == ["2"])
}

@Test func vercelFilterToggles() {
    let items = ["a", "b", "c"]
    // Empty means all: every box is checked.
    #expect(VercelProjectFilter.isChecked("a", in: []))
    // Unchecking one from "all" keeps the others.
    var filter = VercelProjectFilter.toggled("b", on: false, filter: [], items: items)
    #expect(filter == ["a", "c"])
    #expect(!VercelProjectFilter.isChecked("b", in: filter))
    filter = VercelProjectFilter.toggled("a", on: false, filter: filter, items: items)
    #expect(filter == ["c"])
    filter = VercelProjectFilter.toggled("a", on: true, filter: filter, items: items)
    #expect(filter == ["a", "c"])
    // Checking every box again means all, so new projects are watched too.
    filter = VercelProjectFilter.toggled("b", on: true, filter: filter, items: items)
    #expect(filter.isEmpty)
    #expect(VercelProjectFilter.footer(filter: ["a"], items: items) == "Watching 1 of 3")
    #expect(VercelProjectFilter.footer(filter: [], items: items) == nil)
}

@Test func vercelFilterPersistsAsJSONArrayOfNames() throws {
    let defaults = UserDefaults(suiteName: "kobe-tests-\(UUID().uuidString)")!
    #expect(VercelProjectFilter.load(defaults).isEmpty)
    VercelProjectFilter.save(["menuly-web", "docs-site"], to: defaults)
    let data = try #require(defaults.data(forKey: "vercelProjectFilter"))
    let names = try JSONDecoder().decode([String].self, from: data)
    #expect(Set(names) == ["menuly-web", "docs-site"])
    #expect(VercelProjectFilter.load(defaults) == ["menuly-web", "docs-site"])
    defaults.set(Data("garbage".utf8), forKey: "vercelProjectFilter")
    #expect(VercelProjectFilter.load(defaults).isEmpty)
}

// MARK: - Events

@Test func vercelFirstLoadIsSilent() {
    var watcher = VercelWatcher()
    #expect(watcher.update([deployment("1", "a")], filter: []) == nil)
    #expect(watcher.update([deployment("1", "a")], filter: []) == nil)
}

@Test func vercelNewNewestDeploymentFiresOnce() {
    var watcher = VercelWatcher()
    _ = watcher.update([deployment("1", "a")], filter: [])
    let ready = watcher.update([deployment("2", "site"), deployment("1", "a")], filter: [])
    #expect(ready == ServiceEvent(pill: "vercel", kind: .finished, detail: "site · Ready", sound: .finish))
    #expect(watcher.update([deployment("2", "site"), deployment("1", "a")], filter: []) == nil)
    let failed = watcher.update([deployment("3", "site", "ERROR")], filter: [])
    #expect(failed == ServiceEvent(pill: "vercel", kind: .error, detail: "site · Error", sound: .error))
    let canceled = watcher.update([deployment("4", "site", "CANCELED")], filter: [])
    #expect(canceled == ServiceEvent(pill: "vercel", kind: .error, detail: "site · Canceled", sound: .error))
}

@Test func vercelEventsFollowTheProjectFilter() {
    var watcher = VercelWatcher()
    _ = watcher.update([deployment("1", "a")], filter: ["a"])
    // A new deployment of an unwatched project: nothing.
    #expect(watcher.update([deployment("2", "b"), deployment("1", "a")], filter: ["a"]) == nil)
    #expect(watcher.update([deployment("3", "a"), deployment("2", "b")], filter: ["a"])?.detail == "a · Ready")
}

@Test func vercelFirstLoadWithNothingWatchedStillPrimes() {
    var watcher = VercelWatcher()
    #expect(watcher.update([deployment("1", "b")], filter: ["a"]) == nil)
    // The first deployment of a watched project after launch is news.
    #expect(watcher.update([deployment("2", "a"), deployment("1", "b")], filter: ["a"])?.detail == "a · Ready")
}

@Test func vercelResetMakesTheNextLoadSilent() {
    var watcher = VercelWatcher()
    _ = watcher.update([deployment("1", "a")], filter: [])
    watcher.reset()
    #expect(watcher.update([deployment("2", "a")], filter: []) == nil)
}

@Test func vercelDeploymentLinks() {
    #expect(deployment("x", "p").link == URL(string: "https://x.vercel.app"))
    #expect(VercelDeployment(id: "y", projectName: "p", url: "", state: "READY", createdAt: .now,
                             commitMessage: nil, branch: nil).link == nil)
    #expect(Vercel.dashboard == URL(string: "https://vercel.com/dashboard")!)
    #expect(Vercel.tokensPage == URL(string: "https://vercel.com/account/tokens")!)
}
