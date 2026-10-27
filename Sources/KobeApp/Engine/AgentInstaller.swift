import Foundation
import KobeKit

/// Puts Kobe Agent on the engine's side: the Python package and the skill from the app bundle, its config, the
/// service keys it may read (0600, never in argv) and the LaunchAgent that runs it. Everything outside goes through
/// `ShellRunner`. Safe to run again: it replaces what it wrote before.
enum AgentInstaller {
    static let launchAgentLabel = "com.kobe-assistant.agent"
    static let skillName = "kobe-mac-snapshots"

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func install(from source: URL, home: URL, exchangeFolder: String, shared: Bool = false, serviceKeys: ServiceKeys,
                        shell: any ShellRunner) async throws {
        let hermes = home.appendingPathComponent(".hermes").path
        let kobe = hermes + "/kobe"
        let skills = hermes + "/skills"
        try shell.mkdir(kobe)
        try shell.mkdir(skills)
        try await copy(source.path + "/kobe_agent/", to: kobe + "/kobe_agent/", shell: shell, what: "the agent")
        try await copy(source.path + "/skills/\(skillName)/", to: skills + "/\(skillName)/", shell: shell, what: "the skill")

        // Merge into what is there: google_property, google_site and the like belong to the agent, not to us.
        let configPath = kobe + "/config.json"
        var merged: [String: Any] = [:]
        if let text = shell.read(configPath), let data = text.data(using: .utf8),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { merged = old }
        merged["exchange_folder"] = exchangeFolder
        merged["version"] = 1
        if shared { merged["shared"] = true } else { merged.removeValue(forKey: "shared") }
        let config = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys, .prettyPrinted])
        try shell.write(configPath, String(decoding: config, as: UTF8.self), mode: 0o644)

        try await syncSecrets(home: home, serviceKeys: serviceKeys, shell: shell)

        try shell.mkdir(kobe + "/logs")
        let agents = home.appendingPathComponent("Library/LaunchAgents").path
        try shell.mkdir(agents)
        let log = kobe + "/logs/agent.log"
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/env", "python3", "-m", "kobe_agent", "run"],
            "WorkingDirectory": kobe,
            "RunAtLoad": true,
            // Restarted after a crash, not after a clean exit; at most every 10 s.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let plistPath = agents + "/\(launchAgentLabel).plist"
        try shell.write(plistPath, String(decoding: data, as: UTF8.self), mode: 0o644)
        let domain = "gui/\(getuid())"
        _ = await shell.run(["launchctl", "bootout", "\(domain)/\(launchAgentLabel)"], stdin: nil, env: [:])
        let r = await shell.run(["launchctl", "bootstrap", domain, plistPath], stdin: nil, env: [:])
        if r.status != 0 {
            let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "Kobe couldn't start its helper." : "Kobe couldn't start its helper: \(detail)")
        }
    }

    /// `~/.hermes/kobe/secrets/<service>` (0600, the folder 0700) for every service with a key; the file of a
    /// service without one is removed. Keys travel through `write`, never in argv.
    static func syncSecrets(home: URL, serviceKeys: ServiceKeys, shell: any ShellRunner) async throws {
        let secrets = home.appendingPathComponent(".hermes/kobe/secrets").path
        try shell.mkdir(secrets)
        _ = await shell.run(["chmod", "700", secrets], stdin: nil, env: [:])
        for service in Service.allCases {
            let path = secrets + "/" + service.rawValue
            if let key = serviceKeys.load(service) {
                try shell.write(path, key, mode: 0o600)
            } else {
                try shell.remove(path)
            }
        }
    }

    private static func copy(_ from: String, to: String, shell: any ShellRunner, what: String) async throws {
        try shell.mkdir(to)
        let r = await shell.run(["rsync", "-a", "--delete", "--exclude", "__pycache__", from, to], stdin: nil, env: [:])
        if r.status != 0 { throw Failure(message: "Kobe couldn't copy \(what) into Hermes.") }
    }
}
