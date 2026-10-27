import Foundation

/// `--demo`: the engine, brain and connect services get a shell that touches nothing and finds nothing.
struct DemoShell: ShellRunner {
    func run(_ argv: [String], stdin: Data?, env: [String: String]) async -> (status: Int32, stdout: String, stderr: String) {
        // Every command "succeeds" without doing anything, so the demo's Connecting lines tick like the real ones.
        (0, "", "")
    }
    /// Only the bundled agent folder "exists", so the skill line ticks instead of saying it isn't in the build.
    func fileExists(_ path: String) -> Bool { path.hasSuffix("/agent") }
    func read(_ path: String) -> String? { nil }
    func write(_ path: String, _ text: String, mode: Int16) throws {}
    func mkdir(_ path: String) throws {}
    func remove(_ path: String) throws {}
    func list(_ dir: String) -> [String] { [] }
    func modified(_ path: String) -> Date? { nil }
}
