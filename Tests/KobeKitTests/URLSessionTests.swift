import Foundation
import Testing
@testable import KobeKit

@Suite struct KobeURLSessionTests {
    @Test func apiClientsKeepNothingOnDisk() {
        for session in [URLSession.kobeEphemeral, URLSession.kobeLoopback] {
            #expect(session.configuration.urlCache == nil)
            #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
            #expect(session.configuration.httpCookieStorage?.cookieAcceptPolicy != nil)  // ephemeral: in memory only
            #expect(session.configuration.identifier == nil)
        }
    }

    @Test func hermesTalksToTheLoopbackWithoutAProxy() {
        #expect(URLSession.kobeLoopback.configuration.connectionProxyDictionary?.isEmpty == true)
        let api = HermesClient(baseURL: URL(string: "http://127.0.0.1:8642")!, key: { nil })
        #expect(api.session === URLSession.kobeLoopback)
    }

    @Test func theOtherClientsDefaultToTheEphemeralSession() {
        #expect(VercelClient(token: "t").session === URLSession.kobeEphemeral)
        #expect(GitHubClient(token: "t").session === URLSession.kobeEphemeral)
        #expect(StripeClient(key: "rk_test").session === URLSession.kobeEphemeral)
    }
}
