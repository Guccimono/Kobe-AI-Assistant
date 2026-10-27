import Testing
import Foundation
@testable import KobeKit

@Suite struct OnboardingMachineTests {
    @Test func orderMatchesTheMock() {
        #expect(OnboardingStep.allCases == [.welcome, .assistant, .engine, .brain, .connecting, .mac, .connections, .ready])
        #expect(OnboardingMachine.next(after: .welcome) == .assistant)
        #expect(OnboardingMachine.next(after: .connections) == .ready)
        #expect(OnboardingMachine.next(after: .ready) == nil)
    }

    @Test func engineBrainConnectingCannotBeSkipped() {
        for s in OnboardingStep.allCases {
            let locked = [OnboardingStep.engine, .brain, .connecting].contains(s)
            #expect(OnboardingMachine.canSkip(s) == !locked)
        }
    }

    @Test func cannotLeaveEngineUntilRunning() {
        func leave(_ e: EngineState?) -> Bool {
            OnboardingMachine.canLeave(.engine, engine: e, keyVerdict: nil, brainKeptFromHermes: false, connected: false)
        }
        #expect(!leave(nil))
        #expect(!leave(.notInstalled))
        #expect(!leave(.installedApiOff))
        #expect(leave(.running(version: nil)))
        #expect(leave(.running(version: "1.2")))
        #expect(OnboardingMachine.canLeave(.welcome, engine: nil, keyVerdict: nil, brainKeptFromHermes: false, connected: false))
        #expect(OnboardingMachine.canLeave(.ready, engine: nil, keyVerdict: nil, brainKeptFromHermes: false, connected: false))
    }

    @Test func anEngineRunningAsAnotherUserLeavesWithAPastedKey() {
        func engine(_ e: EngineState?, key: Bool) -> Bool {
            OnboardingMachine.canLeave(.engine, engine: e, keyVerdict: nil, brainKeptFromHermes: false, connected: false,
                                       engineElsewhere: true, engineKeySet: key)
        }
        #expect(engine(.notInstalled, key: true))
        #expect(engine(nil, key: true))
        #expect(!engine(.notInstalled, key: false))
        #expect(engine(.running(version: nil), key: false))
        // Same user: a pasted key alone isn't enough.
        #expect(!OnboardingMachine.canLeave(.engine, engine: .notInstalled, keyVerdict: nil, brainKeptFromHermes: false,
                                            connected: false, engineElsewhere: false, engineKeySet: true))
        // The brain lives with the other user: nothing to pick here.
        #expect(OnboardingMachine.canLeave(.brain, engine: nil, keyVerdict: nil, brainKeptFromHermes: false, connected: false,
                                           engineElsewhere: true, engineKeySet: false))
    }

    @Test func brainLeavesOnWorksOrKept() {
        func leave(_ v: KeyVerdict?, kept: Bool = false) -> Bool {
            OnboardingMachine.canLeave(.brain, engine: nil, keyVerdict: v, brainKeptFromHermes: kept, connected: false)
        }
        #expect(!leave(nil))
        // Offline: the key is kept and checked later (step 5 says if it fails).
        #expect(leave(.unreachable))
        #expect(!leave(.refused(by: .openrouter)))
        #expect(leave(.works(models: 0)))
        #expect(leave(.works(models: 40)))
        #expect(leave(nil, kept: true))
        #expect(OnboardingMachine.canLeave(.connecting, engine: nil, keyVerdict: nil, brainKeptFromHermes: false, connected: true))
        #expect(!OnboardingMachine.canLeave(.connecting, engine: nil, keyVerdict: nil, brainKeptFromHermes: false, connected: false))
    }

    @Test func resumesAfterQuit() {
        var p = OnboardingProgress()
        #expect(OnboardingMachine.resumeStep(p) == .welcome)
        p.completed = [.welcome, .assistant, .engine, .brain]
        #expect(OnboardingMachine.resumeStep(p) == .connecting)
        p.completed = Set(OnboardingStep.allCases)
        #expect(OnboardingMachine.resumeStep(p) == .ready)
    }

    @Test func settingsFinishStopsTheWindow() {
        var p = OnboardingProgress()
        #expect(OnboardingMachine.shouldOpenAtLaunch(p, engineKeySet: false))
        #expect(!OnboardingMachine.shouldOpenAtLaunch(p, engineKeySet: true))
        p.finishedFromSettings = true
        #expect(!OnboardingMachine.shouldOpenAtLaunch(p, engineKeySet: false))
        p = OnboardingProgress(); p.done = true
        #expect(!OnboardingMachine.shouldOpenAtLaunch(p, engineKeySet: false))
    }

    @Test func labelsAndHints() {
        #expect(OnboardingMachine.nextLabel(.ready) == "Open the notch")
        #expect(OnboardingMachine.nextLabel(.connections) == "Skip for now ›")
        #expect(OnboardingMachine.nextLabel(.brain) == "Next ›")
        #expect(OnboardingMachine.hint(.welcome) == "Takes about five minutes")
        #expect(OnboardingMachine.hint(.assistant) == "You can change this any time")
        #expect(OnboardingMachine.hint(.engine) == "Kobe never installs anything without a click")
        #expect(OnboardingMachine.hint(.brain) == "Keys stay in your Keychain")
        #expect(OnboardingMachine.hint(.connecting) == "")
        #expect(OnboardingMachine.hint(.mac) == "Permissions are asked on first use")
        #expect(OnboardingMachine.hint(.connections) == "Skip this: Settings has it all")
        #expect(OnboardingMachine.hint(.ready) == "")
    }

    @MainActor @Test func onboardingProgressPersists() {
        let suite = "OnboardingMachineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.onboarding == OnboardingProgress())
        settings.onboarding.completed = [.welcome, .engine]
        settings.onboarding.done = true
        let again = AppSettings(defaults: defaults)
        #expect(again.onboarding.completed == [.welcome, .engine] && again.onboarding.done)
        defaults.set("garbage", forKey: "onboarding")
        #expect(AppSettings(defaults: defaults).onboarding == OnboardingProgress())
    }
}
