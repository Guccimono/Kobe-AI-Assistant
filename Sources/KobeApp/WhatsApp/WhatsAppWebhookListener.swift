import Foundation
import Network
import KobeKit

/// The local door the WhatsApp gateway knocks on with each new message: an HTTP listener bound
/// to 127.0.0.1 only (never reachable from another machine), on the port set in Settings. Each request is handed
/// over whole (16 KB of headers, 1 MB of body at most); one that doesn't finish within 10 s is dropped. Nothing of
/// it is logged.
final class WhatsAppWebhookListener: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "\(Brand.bundleID).whatsapp.webhook")
    private(set) var port: UInt16 = 0

    private let lock = NSLock()
    private var _onRequest: (@Sendable (WAHTTPRequest) -> Int)?
    private var _onListening: (@Sendable (Bool) -> Void)?

    /// Called on `queue` with each complete request; returns the HTTP status to answer.
    var onRequest: (@Sendable (WAHTTPRequest) -> Int)? {
        get { lock.withLock { _onRequest } }
        set { lock.withLock { _onRequest = newValue } }
    }
    /// Called on `queue`: true once listening, false when the port can't be used.
    var onListening: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { _onListening } }
        set { lock.withLock { _onListening = newValue } }
    }

    /// Starts listening; false when the port is invalid or the listener can't be made.
    @discardableResult
    func start(port: UInt16) -> Bool {
        stop()
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        params.acceptLocalOnly = true
        guard let listener = try? NWListener(using: params) else { return false }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onListening?(true)
            case .failed: self?.onListening?(false)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        self.port = port
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func serve(_ connection: NWConnection) {
        // Only the loopback: the listener is bound to it, this is a second lock.
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let a) where a == .loopback: break
            case .ipv6(let a) where a == .loopback: break
            default:
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        // A request that never finishes is dropped.
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch WAHTTPRequest.parse(buffer) {
            case .incomplete where !isComplete && error == nil:
                self.receive(connection, buffer: buffer)
            case .done(let request):
                let status = self.onRequest?(request) ?? 503
                connection.send(content: WAHTTPRequest.response(status, WAHTTPRequest.reason(status)),
                                completion: .contentProcessed { _ in connection.cancel() })
            default:
                connection.send(content: WAHTTPRequest.response(400, WAHTTPRequest.reason(400)),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
