import Darwin
import Foundation
import KobeKit

/// GOWA launched by Kobe ("Start GOWA automatically" in Settings): the binary in Kobe's
/// GOWA folder (or the one picked), started as a child of Kobe on 127.0.0.1 with the URL's port, its basic auth in
/// the environment, its working directory (and so its WhatsApp session) in that folder. Stopped when Kobe quits.
@MainActor
final class WhatsAppGOWAProcess {
    private var process: Process?
    private var lastStart: Date = .distantPast
    /// What the running GOWA was started with: changed, it is restarted; same, left alone.
    private var launchedWith: String?
    /// The GOWA Kobe started, written down so one left behind by a crash is stopped on the next launch.
    private var pidFile: URL?

    var isRunning: Bool { process?.isRunning == true }

    /// Brings GOWA in line with Settings: started when "Start GOWA automatically" is on (and the gateway is GOWA on
    /// this Mac), restarted only when its binary, address or password changed, stopped when the option is off. A
    /// GOWA that keeps dying is started again once a minute at most. Returns false when it can't run (the launch
    /// itself happens a moment later, once any earlier GOWA has let go of the port and its database).
    @discardableResult
    func sync(_ settings: WhatsAppSettings) -> Bool {
        guard let plan = settings.launchPlan() else { stop(); return false }
        switch WAGOWARestart.decide(running: isRunning, launchedWith: launchedWith, signature: plan.signature, lastStart: lastStart) {
        case .keep, .wait: return true
        case .restart, .start: break
        }
        // Claimed now so a second sync() during the wait is a .wait, not a second GOWA.
        lastStart = Date()
        launchedWith = plan.signature
        let old = process
        process = nil
        let folder = settings.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pidFile = folder.appendingPathComponent("kobe-gowa.pid")
        if let own = self.pidFile { try? FileManager.default.removeItem(at: own) }
        self.pidFile = pidFile
        Task {
            // The waits (a second at most each) happen off the main thread: the notch never stalls for GOWA.
            if let old { await Self.terminate(old) }
            await Self.stopLeftover(pidFile: pidFile, binary: plan.binary)
            guard launchedWith == plan.signature else { return }   // stopped or re-planned meanwhile
            launch(plan, folder: folder, pidFile: pidFile)
        }
        return true
    }

    private func launch(_ plan: (binary: String, arguments: [String], environment: [String: String], signature: String),
                        folder: URL, pidFile: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: plan.binary)
        p.arguments = plan.arguments
        p.currentDirectoryURL = folder
        p.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        // GOWA's own output may name contacts or quote messages: it goes nowhere.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            process = p
            try? String(p.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            launchedWith = nil
        }
    }

    /// Stops GOWA if Kobe started it (turned off, a new install): SIGTERM, a second at most for it to go, then
    /// SIGKILL, with the wait off the main thread.
    func stop() {
        launchedWith = nil
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
        guard let p = process else { return }
        process = nil
        Task { await Self.terminate(p) }
    }

    /// At quit only: the same, waiting on the main thread so GOWA is gone before Kobe is.
    func stopNow() {
        launchedWith = nil
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(1)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// SIGTERM, up to a second for the process to end, then SIGKILL; the polling happens on a background thread.
    private static func terminate(_ p: Process) async {
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        await Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(1)
            while kill(pid, 0) == 0 && Date() < deadline { usleep(50_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }.value
    }

    /// A GOWA from an earlier Kobe that didn't quit cleanly still holds the port and the old password: stop it, but
    /// only if that pid really is this GOWA binary.
    private static func stopLeftover(pidFile: URL, binary: String) async {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return }
        try? FileManager.default.removeItem(at: pidFile)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              // The path up to its NUL, decoded as UTF-8 (`String(cString:)` on an array is deprecated).
              case let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: binary).resolvingSymlinksInPath().path else { return }
        kill(pid, SIGTERM)
        await Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(1)
            while kill(pid, 0) == 0 && Date() < deadline { usleep(50_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }.value
    }
}
