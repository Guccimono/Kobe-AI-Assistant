import Foundation
import KobeKit

/// Opens Terminal with a visible command (for the steps the user should watch or answer, like a login).
/// No Apple Events: the command goes into a `.command` file that `open -a Terminal` runs, so no consent prompt.
/// The command must never contain a secret: the file stays on disk until the next launch cleans it.
enum TerminalLauncher {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func folder() -> String {
        NSHomeDirectory() + "/Library/Application Support/\(Brand.dataFolderName)/terminal"
    }

    static func run(_ command: String, shell: any ShellRunner, folder: String = TerminalLauncher.folder()) async throws {
        removeStale(in: folder, shell: shell)
        try shell.mkdir(folder)
        let file = "\(folder)/\(UUID().uuidString).command"
        try shell.write(file, script(for: command), mode: 0o700)
        let r = await shell.run(["open", "-a", "Terminal", file], stdin: nil, env: [:])
        if r.status != 0 {
            throw Failure(message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func script(for command: String) -> String {
        """
        #!/bin/zsh -l
        \(command)
        echo; echo "Done. You can close this window."; exec $SHELL -l

        """
    }

    /// Deletes `.command` files older than a day, left by earlier runs. Only looks when the folder exists.
    static func removeStale(in folder: String, shell: any ShellRunner, now: Date = Date()) {
        guard shell.fileExists(folder) else { return }
        let cutoff = now.addingTimeInterval(-86_400)
        for name in shell.list(folder) where name.hasSuffix(".command") {
            let path = folder + "/" + name
            if let date = shell.modified(path), date < cutoff { try? shell.remove(path) }
        }
    }
}
