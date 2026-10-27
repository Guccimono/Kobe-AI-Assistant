import Foundation
import Testing
@testable import KobeApp
@testable import KobeKit

@MainActor
struct OnboardingTests {
    @Test func opensAtFirstLaunch() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        #expect(model.onboardingShouldOpen)
    }

    @Test func doesNotOpenWhenTheEngineKeyIsSet() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        #expect(model.key.save("engine-key"))
        #expect(!model.onboardingShouldOpen)
    }

    @Test func doesNotReopenAfterSettingsFinish() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        model.settings.onboarding.finishedFromSettings = true
        #expect(!model.onboardingShouldOpen)
    }

    @Test func stepCompletionIsRecorded() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        model.completeStep(.welcome)
        #expect(model.settings.onboarding.completed == [.welcome])
        #expect(!model.settings.onboarding.done)
    }

    @Test func readyClosesAndOpensHome() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let controller = IslandController(app: model, panel: FakePanel(), watchesEvents: false)
        model.controller = controller
        model.island.overlay = .quickAsk
        model.finishOnboarding()
        #expect(model.island.overlay == .none)
        #expect(model.island.tab == .home)
        #expect(model.settings.onboarding.done)
        #expect(model.settings.onboarding.completed.contains(.ready))
        #expect(!model.onboardingShouldOpen)
    }

    @Test func ownsTheEngineServices() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        #expect(model.engine.state == nil)
        #expect(model.connect.hello == nil)
        #expect(model.brain.hermesAlreadyHas == nil)
    }
}

/// A Keychain that refuses every write.
final class RefusingSecrets: SecretStoring, @unchecked Sendable {
    func exists(service: String, account: String) -> Bool { false }
    func fetch(service: String, account: String) -> SecretRead { .missing }
    func write(service: String, account: String, data: Data) -> Bool { false }
    func delete(service: String, account: String) {}
}

@MainActor
struct OnboardingNavTests {
    static let env = "/fake/home/.hermes/.env"

    @Test func engineStepLeavesOnlyWhenRunning() async {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let nav = OnboardingNav(app: model, step: .engine)
        #expect(!nav.canLeave)
        nav.go(1)
        #expect(nav.step == .engine)

        let (demo, cleanupDemo) = TestApp.model(shell: DemoShell())
        defer { cleanupDemo() }
        await demo.engine.check()
        let demoNav = OnboardingNav(app: demo, step: .engine)
        #expect(demoNav.canLeave)
        demoNav.go(1)
        #expect(demoNav.step == .brain)
        #expect(demo.settings.onboarding.completed.contains(.engine))
    }

    @Test func brainStepLeavesWithAWorkingKeyAndStoresIt() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let nav = OnboardingNav(app: model, step: .brain)
        #expect(!nav.canLeave)
        model.settings.selectedBrain = .claude
        nav.pastedKey = "  sk-ant-test \n"
        model.brain.verdict = .works(models: 3)
        nav.checkedBrain = .claude
        #expect(nav.canLeave)
        nav.go(1)
        #expect(nav.step == .connecting)
        #expect(model.brain.storedKey(for: .claude) == "sk-ant-test")
        #expect(nav.pastedKey.isEmpty)
        #expect(nav.checkedBrain == nil)
    }

    @Test func brainStepLeavesOfflineAndKeepsTheKey() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let nav = OnboardingNav(app: model, step: .brain)
        model.settings.selectedBrain = .claude
        nav.pastedKey = "sk-ant-offline"
        model.brain.verdict = .unreachable
        nav.checkedBrain = .claude
        #expect(nav.canLeave)
        nav.go(1)
        #expect(nav.step == .connecting)
        #expect(model.brain.storedKey(for: .claude) == "sk-ant-offline")
    }

    @Test func anotherUsersEngineLeavesTheEngineStepWithAPastedKey() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let nav = OnboardingNav(app: model, step: .engine)
        model.settings.engineSeparateUser = true
        #expect(!nav.canLeave)
        model.key.save("pasted")
        #expect(nav.canLeave)
        nav.go(1)
        #expect(nav.step == .brain)
        #expect(nav.canLeave)
    }

    @Test func aVerdictForAnotherDoorDoesNotCount() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let nav = OnboardingNav(app: model, step: .brain)
        model.brain.verdict = .works(models: 3)
        nav.checkedBrain = .openai
        model.settings.selectedBrain = .claude
        #expect(!nav.canLeave)
    }

    @Test func aKeychainFailureKeepsTheStep() {
        let (model, cleanup) = TestApp.model(secrets: RefusingSecrets())
        defer { cleanup() }
        let nav = OnboardingNav(app: model, step: .brain)
        nav.pastedKey = "sk-ant-test"
        model.brain.verdict = .works(models: 1)
        nav.checkedBrain = model.settings.selectedBrain
        nav.go(1)
        #expect(nav.step == .brain)
        #expect(nav.saveProblem == "Kobe couldn't save the key in your Keychain.")
        #expect(nav.pastedKey == "sk-ant-test")
        #expect(!model.settings.onboarding.completed.contains(.brain))
    }

    @Test func keepingHermesBrainLeavesWithoutAKey() {
        let shell = FakeShell()
        shell.setFile(Self.env, "ANTHROPIC_API_KEY=sk-ant-x\n")
        let (model, cleanup) = TestApp.model(shell: shell)
        defer { cleanup() }
        model.brain.readHermes()
        let nav = OnboardingNav(app: model, step: .brain)
        #expect(!nav.canLeave)
        model.brainKeptFromHermes = true
        #expect(nav.canLeave)
        nav.go(1)
        #expect(nav.step == .connecting)
        #expect(model.settings.selectedBrain == .claude)
    }

    @Test func connectingNeedsTheHello() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let nav = OnboardingNav(app: model, step: .connecting)
        #expect(!nav.canLeave)
    }

    @Test func backAndForwardMoveOneStep() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let nav = OnboardingNav(app: model, step: .welcome)
        nav.go(1)
        #expect(nav.step == .assistant)
        nav.go(-1)
        #expect(nav.step == .welcome)
        nav.go(-1)
        #expect(nav.step == .welcome)
    }

    @Test func readyFinishesAndClosesTheWindow() {
        let (model, cleanup) = TestApp.model()
        defer { cleanup() }
        let nav = OnboardingNav(app: model, step: .ready)
        var closed = false
        nav.closeWindow = { closed = true }
        nav.go(1)
        #expect(closed)
        #expect(model.settings.onboarding.done)
    }
}
