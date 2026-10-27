import Foundation
import KobeKit

/// Runs `MacScripts` through `/usr/bin/osascript`, off the main actor. A child process rather than NSAppleScript:
/// NSAppleScript wants the main thread, and a read of Mail can take seconds (or hang on a slow account), which a
/// process can be killed for. macOS asks the Automation question in Kobe's name (the responsible app).
struct AppleEventsReader: ScriptRunner {
    /// Long enough for the Automation prompt to be answered on the first read.
    var timeout: TimeInterval = 120

    func run(_ source: String) async -> Result<String, MacReadProblem> {
        let timeout = timeout
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // The script goes in on stdin, never in the arguments.
            process.arguments = ["-"]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            do { try process.run() } catch { return .failure(.other("Couldn't run Apple Events")) }
            input.fileHandleForWriting.write(Data(source.utf8))
            try? input.fileHandleForWriting.close()
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            if process.terminationReason == .uncaughtSignal { return .failure(.other("The app took too long to answer")) }
            guard process.terminationStatus == 0 else {
                return .failure(AppleEventsError.from(stderr: String(decoding: err, as: UTF8.self)))
            }
            return .success(String(decoding: out, as: UTF8.self))
        }.value
    }
}
