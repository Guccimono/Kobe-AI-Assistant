import Foundation

/// What the onboarding's engine screen can show. Pure rules: the app observes, this decides.
public enum EngineState: Equatable, Sendable {
    case running(version: String?)
    case installedApiOff
    case notInstalled
}

/// What the app observed: the health endpoint and the files on disk.
public struct EngineProbe: Equatable, Sendable {
    public var healthReachable: Bool
    public var version: String?
    public var hermesHome: Bool
    public var hermesBinary: Bool

    public init(healthReachable: Bool, version: String?, hermesHome: Bool, hermesBinary: Bool) {
        self.healthReachable = healthReachable
        self.version = version
        self.hermesHome = hermesHome
        self.hermesBinary = hermesBinary
    }
}

public enum EngineDetection {
    public static let installCommand = "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
    public static let hermesHome = "~/.hermes/hermes-agent"
    public static let hermesBinary = "~/.local/bin/hermes"

    public static func state(_ p: EngineProbe) -> EngineState {
        if p.healthReachable { return .running(version: p.version) }
        if p.hermesHome || p.hermesBinary { return .installedApiOff }
        return .notInstalled
    }

    public static func healthURL(base: URL) -> URL {
        base.appendingPathComponent("health")
    }

    public static func detailedURL(base: URL) -> URL {
        base.appendingPathComponent("health").appendingPathComponent("detailed")
    }

    public static func title(_ s: EngineState) -> String {
        switch s {
        case .running: "Hermes is here."
        case .installedApiOff: "Hermes is here, asleep."
        case .notInstalled: "Hermes isn't installed yet."
        }
    }

    public static func line(_ s: EngineState, base: URL) -> String {
        switch s {
        case .running(let version):
            var host = base.host ?? "127.0.0.1"
            if let port = base.port { host += ":\(port)" }
            var text = "Found at \(host)"
            if let version, !version.isEmpty { text += " · version \(version)" }
            return text
        case .installedApiOff:
            return "Found ~/.hermes. Its API server is off. Kobe can turn it on for you."
        case .notInstalled:
            return "One command, run in Terminal where you can watch it. Takes a minute or two."
        }
    }
}
