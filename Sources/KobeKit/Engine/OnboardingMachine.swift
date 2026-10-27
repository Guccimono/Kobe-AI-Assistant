import Foundation

/// The eight first-run steps, in the order of the mock.
public enum OnboardingStep: Int, CaseIterable, Codable, Sendable {
    case welcome, assistant, engine, brain, connecting, mac, connections, ready
}

/// What survives a quit: which steps were finished, and whether the window is done for good.
public struct OnboardingProgress: Codable, Equatable, Sendable {
    public var completed: Set<OnboardingStep>
    public var finishedFromSettings: Bool
    public var done: Bool

    public init(completed: Set<OnboardingStep> = [], finishedFromSettings: Bool = false, done: Bool = false) {
        self.completed = completed
        self.finishedFromSettings = finishedFromSettings
        self.done = done
    }
}

public enum OnboardingMachine {
    public static func next(after s: OnboardingStep) -> OnboardingStep? {
        OnboardingStep(rawValue: s.rawValue + 1)
    }

    /// Engine, brain and connecting are the steps Kobe cannot work without.
    public static func canSkip(_ s: OnboardingStep) -> Bool {
        switch s {
        case .engine, .brain, .connecting: false
        default: true
        }
    }

    /// The Ollama door counts as `keyVerdict: .works(models: 0)` when Ollama is detected. An unreachable provider
    /// lets the person go on (the key is kept; step 5 shows whether it works). `engineElsewhere`: Hermes runs as
    /// another macOS user, so a pasted engine key is enough for the engine step and the brain is set over there.
    public static func canLeave(_ s: OnboardingStep, engine: EngineState?, keyVerdict: KeyVerdict?,
                                brainKeptFromHermes: Bool, connected: Bool,
                                engineElsewhere: Bool = false, engineKeySet: Bool = false) -> Bool {
        switch s {
        case .engine:
            if case .running = engine { return true }
            return engineElsewhere && engineKeySet
        case .brain:
            switch keyVerdict {
            case .works?, .unreachable?: return true
            default: return brainKeptFromHermes || engineElsewhere
            }
        case .connecting:
            return connected
        default:
            return true
        }
    }

    /// The first step not yet completed; all done lands on `.ready`.
    public static func resumeStep(_ p: OnboardingProgress) -> OnboardingStep {
        OnboardingStep.allCases.first { !p.completed.contains($0) } ?? .ready
    }

    /// An already-configured Mac (engine key set) never sees the window.
    public static func shouldOpenAtLaunch(_ p: OnboardingProgress, engineKeySet: Bool) -> Bool {
        !p.done && !p.finishedFromSettings && !engineKeySet
    }

    public static func nextLabel(_ s: OnboardingStep) -> String {
        switch s {
        case .ready: "Open the notch"
        case .connections: "Skip for now ›"
        default: "Next ›"
        }
    }

    public static func hint(_ s: OnboardingStep) -> String {
        switch s {
        case .welcome: "Takes about five minutes"
        case .assistant: "You can change this any time"
        case .engine: "Kobe never installs anything without a click"
        case .brain: "Keys stay in your Keychain"
        case .connecting: ""
        case .mac: "Permissions are asked on first use"
        case .connections: "Skip this: Settings has it all"
        case .ready: ""
        }
    }
}
