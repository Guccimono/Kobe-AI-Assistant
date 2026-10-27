import Foundation
import Synchronization

/// Minimal per-host HTTP stub for the app target's tests (a trimmed copy of KobeKitTests' `StubURLProtocol`:
/// test targets can't share files). Each test uses its own host, so parallel tests never share state.
final class StubHTTP: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> Int

    static let handlers = Mutex<[String: Handler]>([:])
    static let bodies = Mutex<[String: @Sendable (URLRequest) -> Data?]>([:])
    static let seen = Mutex<[String: [URLRequest]]>([:])

    /// A fresh host plus a URLSession routed through this stub. The handler returns a status code.
    static func make(body: (@Sendable (URLRequest) -> Data?)? = nil, _ handler: @escaping Handler) -> (base: URL, session: URLSession, host: String) {
        let host = "t\(UUID().uuidString.prefix(8).lowercased()).test"
        handlers.withLock { $0[host] = handler }
        if let body { bodies.withLock { $0[host] = body } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHTTP.self]
        return (URL(string: "http://\(host):8642")!, URLSession(configuration: config), host)
    }

    static func requests(_ host: String) -> [URLRequest] { seen.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.seen.withLock { $0[host, default: []].append(request) }
        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        let status = handler(request)
        let custom = Self.bodies.withLock { $0[host] }?(request)
        let fallback: Data = request.url?.path.hasSuffix("detailed") == true && status == 200
            ? Data(#"{"status":"ok","version":"1.2.3"}"#.utf8) : Data("{}".utf8)
        let body = custom ?? fallback
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
