import Foundation
import Testing
@testable import KobeApp

struct ShellRunnerTests {
    @Test func processShellRunsTrue() async {
        let r = await ProcessShell().run(["/usr/bin/true"], stdin: nil, env: [:])
        #expect(r.status == 0)
    }

    @Test func processShellCapturesStdoutAndStdin() async {
        let r = await ProcessShell().run(["/bin/cat"], stdin: Data("hi".utf8), env: [:])
        #expect(r.status == 0)
        #expect(r.stdout == "hi")
    }

    @Test func processShellReportsFailureAndStderr() async {
        let r = await ProcessShell().run(["/bin/sh", "-c", "echo oops >&2; exit 3"], stdin: nil, env: [:])
        #expect(r.status == 3)
        #expect(r.stderr.contains("oops"))
    }

    @Test func prependsUserBin() async {
        let r = await ProcessShell().run(["/bin/sh", "-c", "echo $PATH"], stdin: nil, env: [:])
        let home = NSHomeDirectory()
        #expect(r.stdout.hasPrefix("\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:"))
    }

    @Test func envIsMergedOverTheProcessEnvironment() async {
        let r = await ProcessShell().run(["/bin/sh", "-c", "echo $KOBE_TEST_VAR"], stdin: nil, env: ["KOBE_TEST_VAR": "yes"])
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "yes")
    }

    @Test func processShellFileIO() throws {
        let dir = NSTemporaryDirectory() + "kobe-shell-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let shell = ProcessShell()
        let file = dir + "/a/b/secret"
        try shell.mkdir(dir + "/a/b")
        #expect(shell.fileExists(dir + "/a/b"))
        try shell.write(file, "x", mode: 0o600)
        #expect(shell.read(file) == "x")
        let perms = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        try shell.remove(file)
        #expect(!shell.fileExists(file))
    }

    @Test func fakeShellRecordsCallsAndFiles() async throws {
        let shell = FakeShell()
        shell.script(["hermes", "status"], status: 0, stdout: "running")
        shell.script(["hermes"], status: 1, stderr: "nope")
        let a = await shell.run(["hermes", "status", "--all"], stdin: Data("in".utf8), env: [:])
        let b = await shell.run(["hermes", "other"], stdin: nil, env: [:])
        #expect(a.stdout == "running" && a.status == 0)
        #expect(b.status == 1 && b.stderr == "nope")
        #expect(shell.calls == [["hermes", "status", "--all"], ["hermes", "other"]])
        #expect(shell.stdins.first == Data("in".utf8))
        try shell.mkdir("/h/kobe")
        try shell.write("/h/kobe/secrets", "k", mode: 0o600)
        #expect(shell.fileExists("/h/kobe/secrets") && shell.fileExists("/h/kobe"))
        #expect(shell.read("/h/kobe/secrets") == "k")
        #expect(shell.modes["/h/kobe/secrets"] == 0o600)
        try shell.remove("/h/kobe/secrets")
        #expect(shell.read("/h/kobe/secrets") == nil)
    }

    /// Convention: a secret travels on stdin or in a 0600 file, never in argv. Later tasks assert this.
    @Test func noSecretEverInArgv() async {
        let shell = FakeShell()
        _ = await shell.run(["hermes", "config", "set"], stdin: Data("sk-secret".utf8), env: [:])
        #expect(!shell.argvContains("sk-"))
        _ = await shell.run(["hermes", "sk-leak"], stdin: nil, env: [:])
        #expect(shell.argvContains("sk-"))
    }

    @Test func terminalScriptKeepsTheWindowOpen() {
        let s = TerminalLauncher.script(for: "hermes login")
        #expect(s.hasPrefix("#!/bin/zsh -l\nhermes login\n"))
        #expect(s.contains("echo; echo \"Done. You can close this window.\"; exec $SHELL -l"))
    }

    @Test func terminalWritesAnExecutableFileAndOpensIt() async throws {
        let shell = FakeShell()
        try await TerminalLauncher.run("hermes login", shell: shell, folder: "/t/terminal")
        let (path, text) = try #require(shell.files.first)
        #expect(path.hasPrefix("/t/terminal/") && path.hasSuffix(".command"))
        #expect(text.contains("hermes login"))
        #expect(shell.modes[path] == 0o700)
        #expect(shell.calls == [["open", "-a", "Terminal", path]])
    }

    @Test func terminalThrowsWhenOpenFails() async {
        let shell = FakeShell()
        shell.script(["open"], status: 1, stderr: "no Terminal")
        await #expect(throws: TerminalLauncher.Failure.self) {
            try await TerminalLauncher.run("x", shell: shell, folder: "/t")
        }
    }

    @Test func emptyArgvAnswers127() async {
        let r = await ProcessShell().run([], stdin: nil, env: [:])
        #expect(r.status == 127)
    }

    @Test func writeNeverLeavesAWiderSiblingOrMode() throws {
        let dir = NSTemporaryDirectory() + "kobe-write-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let shell = ProcessShell()
        try shell.mkdir(dir)
        let file = dir + "/secrets"
        try shell.write(file, "one", mode: 0o600)
        try shell.write(file, "two", mode: 0o600)
        #expect(shell.read(file) == "two")
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["secrets"])
    }

    @Test func writeGoesThroughASymlinkToTheRealFile() throws {
        let dir = NSTemporaryDirectory() + "kobe-link-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fm = FileManager.default
        let shell = ProcessShell()
        try shell.mkdir(dir + "/dotfiles")
        let real = dir + "/dotfiles/config.yaml"
        try "old\n".write(toFile: real, atomically: true, encoding: .utf8)
        let link = dir + "/config.yaml"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "dotfiles/config.yaml")
        try shell.write(link, "new\n", mode: 0o600)
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == "dotfiles/config.yaml")
        #expect(try String(contentsOfFile: real, encoding: .utf8) == "new\n")
        #expect(try fm.attributesOfItem(atPath: real)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.contentsOfDirectory(atPath: dir + "/dotfiles") == ["config.yaml"])
    }

    @Test func staleCommandFilesAreRemovedAndFreshKept() async throws {
        let shell = FakeShell()
        let folder = "/t/terminal"
        try shell.mkdir(folder)
        shell.setFile(folder + "/old.command", "x", modified: Date().addingTimeInterval(-2 * 86_400))
        shell.setFile(folder + "/fresh.command", "x", modified: Date().addingTimeInterval(-60))
        try await TerminalLauncher.run("hermes login", shell: shell, folder: folder)
        #expect(shell.files[folder + "/old.command"] == nil)
        #expect(shell.files[folder + "/fresh.command"] != nil)
        #expect(shell.files.keys.contains { $0.hasSuffix(".command") && !$0.hasSuffix("old.command") && !$0.hasSuffix("fresh.command") })
    }

    @Test func staleCleanupSkipsAMissingFolder() async throws {
        let shell = FakeShell()
        shell.setFile("/t/terminal/old.command", "x", modified: .distantPast)
        TerminalLauncher.removeStale(in: "/t/terminal", shell: shell)
        #expect(shell.files["/t/terminal/old.command"] != nil)
    }
}
