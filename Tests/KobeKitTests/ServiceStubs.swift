import Foundation
@testable import KobeKit

/// A stubbed session for a service client: the first route whose key appears in "path?query" answers with that
/// fixture file; anything else is a 404. Returns the session, the stub's host (for StubURLProtocol.requests) and base.
func stubbed(_ routes: [String: String], status: Int = 200) -> (URLSession, String, URL) {
    let stub = StubURLProtocol.make { request in
        let path = request.url?.path ?? ""
        let query = request.url?.query ?? ""
        for (key, file) in routes where (path + "?" + query).contains(key) {
            return .init(status: status, body: StubURLProtocol.fixture(file))
        }
        return .init(status: 404, body: Data("{}".utf8))
    }
    return (stub.session, stub.base.host()!, stub.base)
}
