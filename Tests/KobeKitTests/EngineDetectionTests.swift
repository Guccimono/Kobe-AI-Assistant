import Foundation
import Testing
@testable import KobeKit

@Suite struct EngineDetectionTests {
    @Test func runningWinsOverFiles() {
        let p = EngineProbe(healthReachable: true, version: "0.9.1", hermesHome: true, hermesBinary: true)
        #expect(EngineDetection.state(p) == .running(version: "0.9.1"))
        let bare = EngineProbe(healthReachable: true, version: nil, hermesHome: false, hermesBinary: false)
        #expect(EngineDetection.state(bare) == .running(version: nil))
    }

    @Test func filesWithoutHealthIsApiOff() {
        let home = EngineProbe(healthReachable: false, version: nil, hermesHome: true, hermesBinary: false)
        let bin = EngineProbe(healthReachable: false, version: nil, hermesHome: false, hermesBinary: true)
        #expect(EngineDetection.state(home) == .installedApiOff)
        #expect(EngineDetection.state(bin) == .installedApiOff)
    }

    @Test func nothingIsNotInstalled() {
        let p = EngineProbe(healthReachable: false, version: nil, hermesHome: false, hermesBinary: false)
        #expect(EngineDetection.state(p) == .notInstalled)
    }

    @Test func usesTheConfiguredURL() {
        let base = URL(string: "http://127.0.0.1:8643")!
        #expect(EngineDetection.healthURL(base: base).absoluteString == "http://127.0.0.1:8643/health")
        #expect(EngineDetection.detailedURL(base: base).absoluteString == "http://127.0.0.1:8643/health/detailed")
    }

    @Test func copyPerState() {
        let base = URL(string: "http://127.0.0.1:8642")!
        #expect(EngineDetection.title(.running(version: nil)) == "Hermes is here.")
        #expect(EngineDetection.title(.installedApiOff) == "Hermes is here, asleep.")
        #expect(EngineDetection.title(.notInstalled) == "Hermes isn't installed yet.")
        #expect(EngineDetection.line(.running(version: "0.9.1"), base: base) == "Found at 127.0.0.1:8642 · version 0.9.1")
        #expect(EngineDetection.line(.running(version: nil), base: base) == "Found at 127.0.0.1:8642")
        #expect(EngineDetection.line(.installedApiOff, base: base) == "Found ~/.hermes. Its API server is off. Kobe can turn it on for you.")
        #expect(EngineDetection.line(.notInstalled, base: base) == "One command, run in Terminal where you can watch it. Takes a minute or two.")
        #expect(EngineDetection.installCommand == "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash")
    }
}
