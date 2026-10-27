import Foundation
import Testing

@Suite struct ScrubTests {
    /// The banned words, shared with `scripts/export-public.sh`. Not in the public export (it names what it guards):
    /// there the scan has nothing to check, and the export script ran the same list before publishing.
    static let wordsFile = "scripts/publish-banned-words.txt"
    /// Tracked paths the export leaves out, and so the scan too.
    static let excludedPrefixes = ["docs/superpowers/", "docs/legal/", ".superpowers/"]
    static let excludedFiles: Set<String> = [wordsFile, "CLAUDE.local.md"]
    /// Allowed anywhere: the public repository's address and the two-user mode's shared folder. Lower case, built
    /// from pieces so this file does not trip the scan it runs.
    static let allowedEverywhere = [["gucci", "mono/kobe-ai-assistant"], ["/users/shared/", "hermes-", "exchange"]].map { $0.joined() }
    /// Allowed in one file each: the copyright line and the credits (the same tokens as the export script's).
    static let allowedIn: [String: [String]] = {
        let copyright = ["copyright (c) 2026 gauth", "ier couser", "gue"].joined()
        let credit = ["der", "ive from cou", "cou"].joined()
        return [
            "LICENSE": [copyright],
            "NOTICE": [copyright, ["cou", "cou, by louis rail", "lé"].joined(), credit + ". " + ["cou", "cou"].joined()],
            "README.md": [credit + " by louis " + ["rail", "lé"].joined()],
        ]
    }()

    static func packageRoot(from file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: file)
    }

    /// One word per line; blank lines and `#` comments skipped; nil when the file isn't there.
    static func bannedWords() -> [String]? {
        guard let text = try? String(contentsOf: packageRoot().appendingPathComponent(wordsFile), encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Every file git tracks, minus the ones the export leaves out (paths relative to the package root).
    static func trackedFiles() -> [String] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "-C", packageRoot().path, "ls-files", "-z"]
        let out = Pipe()
        git.standardOutput = out
        git.standardError = FileHandle.nullDevice
        guard (try? git.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { return [] }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            .filter { path in !excludedFiles.contains(path) && !excludedPrefixes.contains { path.hasPrefix($0) } }
    }

    /// ASCII upper case folded to lower, byte by byte: independent of the file's text encoding.
    static func folded(_ data: Data) -> Data { Data(data.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }) }

    /// The banned words left in `data` once the allowed tokens are taken out of each line.
    static func hits(in data: Data, file: String, words: [String]) -> [String] {
        let allowed = (allowedEverywhere + (allowedIn[file] ?? [])).map { Data($0.utf8) }
        let needles = words.map { ($0, folded(Data($0.utf8))) }
        var found: [String] = []
        for raw in folded(data).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var line = Data(raw)
            for phrase in allowed {
                while let range = line.range(of: phrase) { line.removeSubrange(range) }
            }
            for (word, bytes) in needles where line.range(of: bytes) != nil && !found.contains(word) { found.append(word) }
        }
        return found
    }

    @Test func noPersonalDataInTheTree() throws {
        guard let words = Self.bannedWords() else { return }   // the public export: see `wordsFile`
        #expect(words.count >= 10)
        let files = Self.trackedFiles()
        #expect(files.count > 300)
        let root = Self.packageRoot()
        for file in files {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { continue }  // deleted, not yet staged
            for word in Self.hits(in: data, file: file, words: words) {
                Issue.record("\(file) contains \(word)")
            }
        }
    }

    @Test func allowedTokensAreLineLevel() {
        let words = [["gauth", "ier"].joined(), ["cou", "cou"].joined()]
        let copyright = Data(["Copyright (c) 2026 Gauth", "ier Couser", "gue"].joined().utf8)
        #expect(Self.hits(in: copyright, file: "LICENSE", words: words).isEmpty)
        #expect(Self.hits(in: copyright, file: "Sources/x.swift", words: words) == [words[0]])
        // An allowed token on a line doesn't excuse another banned word on it.
        let mixed = Data((["Copyright (c) 2026 Gauth", "ier Couser", "gue"].joined() + " and " + words[1]).utf8)
        #expect(Self.hits(in: mixed, file: "LICENSE", words: words) == [words[1]])
    }

    @Test func theExportReadsTheSameList() throws {
        let script = try String(contentsOf: Self.packageRoot().appendingPathComponent("scripts/export-public.sh"), encoding: .utf8)
        #expect(script.contains(Self.wordsFile))
    }

    @Test func repoHasLicenceAndNotice() throws {
        let root = Self.packageRoot()
        func text(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        #expect(try text("LICENSE").contains("MIT License"))
        let notice = try text("NOTICE")
        #expect(notice.contains("Phosphor"))
        #expect(notice.contains("MIT"))
        let firstHeading = try text("README.md").split(separator: "\n").first { $0.hasPrefix("# ") }
        #expect(firstHeading?.contains("Kobe") == true)
    }
}
