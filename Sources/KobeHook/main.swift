// kobe-hook: called by Claude Code hooks. Reads the hook JSON from stdin and forwards it to Kobe over a local Unix
// socket only this user can open. Never blocks Claude for long and never fails: if Kobe isn't running it exits 0
// with no output and Claude carries on as usual.
//
// PermissionRequest and `--ask` (PreToolUse on AskUserQuestion) wait for an answer in the notch, 90 s by default
// (`claudeWait` in Kobe's settings, or KOBE_HOOK_WAIT, at least 1 s). No answer, a timeout or "answer in Claude" = no
// output, so Claude asks in its own UI.
//
// Only Kobe is talked to: whatever listens at the socket path must be a process whose executable ends with
// Kobe.app/Contents/MacOS/Kobe (any location, so a dev build in build/Kobe.app counts; KOBE_HOOK_PEER overrides the
// suffix for tests). Anything else gets nothing and the hook exits 0, so Claude Code is never blocked or steered.

import Foundation

let socketPath = NSHomeDirectory() + "/Library/Application Support/Kobe/claude.sock"
let input = FileHandle.standardInput.readDataToEndOfFile()
guard var hook = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
let event = hook["hook_event_name"] as? String
let asking = CommandLine.arguments.contains("--ask")
let waitsForAnswer = event == "PermissionRequest" || (asking && event == "PreToolUse")
let wait = max(1, Int(ProcessInfo.processInfo.environment["KOBE_HOOK_WAIT"] ?? "")
    ?? (CFPreferencesCopyAppValue("claudeWait" as CFString, "com.kobe-assistant.app" as CFString) as? Int)
    ?? 90)
let expectedPeer = ProcessInfo.processInfo.environment["KOBE_HOOK_PEER"] ?? "Kobe.app/Contents/MacOS/Kobe"

/// The executable of the process at the other end of the socket, from its pid.
func peerPath(of fd: Int32) -> String? {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: 4096)
    let size = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard size > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

// Claude Code fires both the plain PreToolUse hook and the --ask one for AskUserQuestion: only --ask waits.
if asking { hook["_ask"] = true }
// Which app runs Claude, so "Open terminal" can bring it forward.
hook["_term_program"] = ProcessInfo.processInfo.environment["TERM_PROGRAM"]
hook["_bundle_id"] = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var noSigpipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: Array(socketPath.utf8.prefix(raw.count - 1)))
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0, var message = try? JSONSerialization.data(withJSONObject: hook) else { exit(0) }  // Kobe isn't running
guard peerPath(of: fd)?.hasSuffix(expectedPeer) == true else { exit(0) }  // not Kobe at the socket: say nothing

message.append(0x0A)
_ = message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
guard waitsForAnswer else { close(fd); exit(0) }

var timeout = timeval(tv_sec: wait, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
var reply = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while !reply.contains(0x0A) {
    let n = read(fd, &buffer, buffer.count)
    if n <= 0 { break }
    reply.append(contentsOf: buffer[0..<n])
}
close(fd)

guard let answer = (try? JSONSerialization.jsonObject(with: reply.prefix { $0 != 0x0A })) as? [String: Any] else { exit(0) }

let output: [String: Any]
if event == "PermissionRequest" {
    guard let behavior = answer["behavior"] as? String, behavior == "allow" || behavior == "deny" else { exit(0) }
    var decision: [String: Any] = ["behavior": behavior]
    if behavior == "deny" { decision["message"] = "Denied from the Kobe notch." }
    output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
} else {
    // A question answered in the notch: Claude Code gets the answers in the tool's input and carries on.
    guard answer["decision"] as? String == "answer", let answers = answer["answers"] as? [String: Any] else { exit(0) }
    let questions = (hook["tool_input"] as? [String: Any])?["questions"] ?? []
    output = ["hookSpecificOutput": [
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "updatedInput": ["questions": questions, "answers": answers],
    ]]
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: output))
exit(0)
