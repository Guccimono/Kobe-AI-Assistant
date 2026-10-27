import Foundation
import Synchronization

/// Serves canned responses per host, so parallel tests never share state: each test uses its own host.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var error: URLError?
    }
    typealias Handler = @Sendable (URLRequest) -> Reply

    static let handlers = Mutex<[String: Handler]>([:])
    static let seen = Mutex<[String: [URLRequest]]>([:])

    /// A fresh host plus a URLSession routed through this stub.
    static func make(_ handler: @escaping Handler) -> (base: URL, session: URLSession, host: String) {
        let host = "t\(UUID().uuidString.prefix(8).lowercased()).test"
        handlers.withLock { $0[host] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return (URL(string: "http://\(host):8642")!, URLSession(configuration: config), host)
    }

    static func requests(_ host: String) -> [URLRequest] { seen.withLock { $0[host] ?? [] } }

    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            request.httpBody = data
        }
        let host = request.url?.host ?? ""
        Self.seen.withLock { $0[host, default: []].append(request) }
        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        let reply = handler(request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
