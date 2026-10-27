import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case unknown
    case noKey
    case offline(retryIn: Int)
    case unauthorized
    case connected(version: String?)
}

/// Whether Kobe (Hermes) answers. Offline retries back off 1, 2, 4 … 60 s; a missing or refused key waits until
/// `check()` is called again (after the key is saved). Nothing polls while connected.
@MainActor
@Observable
public final class Connection {
    public static let backoff = [1, 2, 4, 8, 16, 32, 60]

    public private(set) var state: ConnectionState = .unknown
    public private(set) var health: HermesHealth?

    @ObservationIgnored private let api: any HermesAPI
    @ObservationIgnored private let keyIsSet: @Sendable () -> Bool
    @ObservationIgnored private let sleep: @Sendable (Int) async -> Void
    @ObservationIgnored private var checking = false

    public init(api: any HermesAPI, keyIsSet: @escaping @Sendable () -> Bool,
                sleep: @escaping @Sendable (Int) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.api = api
        self.keyIsSet = keyIsSet
        self.sleep = sleep
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Checks now, and keeps retrying while offline. Returns once connected, or on a key problem.
    public func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var attempt = 0
        while true {
            guard keyIsSet() else { state = .noKey; return }
            do {
                let health = try await api.health()
                self.health = health
                state = .connected(version: health.version)
                return
            } catch HermesError.unauthorized {
                state = .unauthorized
                return
            } catch HermesError.noKey {
                state = .noKey
                return
            } catch {
                let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
                attempt += 1
                state = .offline(retryIn: delay)
                await sleep(delay)
                if Task.isCancelled { return }
            }
        }
    }

    /// A request failed after connecting: show it, and keep retrying while Kobe is offline.
    public func noteFailure(_ error: HermesError) async {
        switch error {
        case .unauthorized: state = .unauthorized
        case .noKey: state = .noKey
        case .offline: await check()
        default: break
        }
    }
}
