import Foundation

public extension URLSession {
    /// The session every API client uses unless a test injects its own: ephemeral, so no response (chat text,
    /// invoices, deployments) is ever written to the shared on-disk URL cache or cookie store.
    static let kobeEphemeral: URLSession = URLSession(configuration: .kobeEphemeral)

    /// For Hermes on 127.0.0.1: ephemeral too, and never through a system or PAC proxy.
    static let kobeLoopback: URLSession = {
        let config = URLSessionConfiguration.kobeEphemeral
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()
}

extension URLSessionConfiguration {
    /// Ephemeral, and told not to use any cache at all.
    static var kobeEphemeral: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }
}
