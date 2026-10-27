import Foundation
import Testing
@testable import KobeKit

// GitHubClient against stubbed api.github.com routes.

@Test func statsAddPublicAndOwnedPrivateReposAndSumStars() async throws {
    let (session, host, base) = stubbed(["/user?": "github_user.json", "/user/repos": "github_user_repos.json"])
    let client = GitHubClient(token: "ghp_test", session: session, base: base)
    let stats = try await client.stats()
    #expect(stats == GitHubStats(totalRepos: 17, totalStars: 1234))

    let requests = StubURLProtocol.requests(host)
    #expect(requests.count == 2)
    #expect(requests[0].url?.path == "/user")
    #expect(requests[0].timeoutInterval == 10)
    #expect(requests[1].url?.path == "/user/repos")
    #expect(requests[1].url?.query == "per_page=100&affiliation=owner&sort=pushed")
    #expect(requests[1].timeoutInterval == 15)
    for request in requests {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.httpMethod == "GET")
    }
}

@Test func statsFallBackToTotalPrivateRepos() async throws {
    let (session, _, base) = stubbed(["/user?": "github_user_no_owned.json", "/user/repos": "github_user_repos.json"])
    let stats = try await GitHubClient(token: "t", session: session, base: base).stats()
    #expect(stats.totalRepos == 7)
}

@Test func pulsePostsTheGraphQLQuery() async throws {
    let (session, host, base) = stubbed(["/graphql": "github_pulse.json"])
    let pulse = try await GitHubClient(token: "ghp_test", session: session, base: base).pulse()
    #expect(pulse.myPRs.count == 3)

    let request = try #require(StubURLProtocol.requests(host).first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/graphql")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.timeoutInterval == 15)
    let body = try #require(request.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let query = try #require(json["query"] as? String)
    #expect(query.contains("statusCheckRollup"))
    #expect(query.contains("review-requested:@me"))
    #expect(query.contains("pullRequests(states: OPEN, first: 20"))
    #expect(query.contains("repositories(first: 10, ownerAffiliations: [OWNER]"))
}

@Test func activityPostsTheCalendarQuery() async throws {
    let (session, host, base) = stubbed(["/graphql": "github_activity.json"])
    let activity = try await GitHubClient(token: "t", session: session, base: base).activity()
    #expect(activity.total == 1234)
    let body = try #require(StubURLProtocol.requests(host).first?.httpBody)
    let query = try #require((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["query"] as? String)
    #expect(query.contains("contributionCalendar"))
}

@Test func partialGraphQLErrorsStillGiveAPulse() async throws {
    let (session, _, base) = stubbed(["/graphql": "github_pulse_partial.json"])
    let pulse = try await GitHubClient(token: "t", session: session, base: base).pulse()
    #expect(pulse.login == "samrivera")
}

@Test func graphQLErrorsWithoutDataFail() async {
    let (session, _, base) = stubbed(["/graphql": "github_graphql_errors.json"])
    await #expect(throws: ServiceError.failed("Something went wrong")) {
        try await GitHubClient(token: "t", session: session, base: base).pulse()
    }
    await #expect(throws: ServiceError.failed("Something went wrong")) {
        try await GitHubClient(token: "t", session: session, base: base).activity()
    }
}

@Test func refusedTokenIsBadKey() async {
    let (session, _, base) = stubbed(["/": "error_401.json"], status: 401)
    let client = GitHubClient(token: "t", session: session, base: base)
    await #expect(throws: ServiceError.badKey) { try await client.pulse() }
    await #expect(throws: ServiceError.badKey) { try await client.stats() }
}

@Test func serverErrorsAreReported() async {
    let (session, _, base) = stubbed(["/": "error_401.json"], status: 502)
    await #expect(throws: ServiceError.failed("HTTP 502")) {
        try await GitHubClient(token: "t", session: session, base: base).activity()
    }
}

@Test func unreachableIsOffline() async {
    let stub = StubURLProtocol.make { _ in .init(error: URLError(.notConnectedToInternet)) }
    await #expect(throws: ServiceError.offline) {
        try await GitHubClient(token: "t", session: stub.session, base: stub.base).pulse()
    }
}

@Test func defaultBaseIsTheGitHubAPI() {
    #expect(GitHubClient.api.absoluteString == "https://api.github.com")
}
