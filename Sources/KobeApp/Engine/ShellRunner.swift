import Foundation

/// The onboarding's seam to the outside world: run a process, and the small file I/O the engine services need.
/// A secret never goes in `argv`: pass it on `stdin` or through a 0600 file written with `write`.
protocol ShellRunner: Sendable {
    func run(_ argv: [String], stdin: Data?, env: [String: String]) async -> (status: Int32, stdout: String, stderr: String)
    func fileExists(_ path: String) -> Bool
    func read(_ path: String) -> String?
    /// Writes `text` and then sets the POSIX `mode` (0o600 for secrets).
    func write(_ path: String, _ text: String, mode: Int16) throws
    /// Creates the folder and any missing parents.
    func mkdir(_ path: String) throws
    func remove(_ path: String) throws
    /// File names (not paths) directly inside `dir`; empty when it doesn't exist.
    func list(_ dir: String) -> [String]
    /// The modification date, nil when the file doesn't exist.
    func modified(_ path: String) -> Date?
}

/// The real thing: `Process` through `/usr/bin/env` so `hermes`, `launchctl`, `ollama` resolve on PATH.
struct ProcessShell: ShellRunner {
    init() {}

    /// The user's tool folders come first: a GUI app starts with a bare PATH.
    static func environment(merging env: [String: String], base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var merged = base
        for (k, v) in env { merged[k] = v }
        let home = NSHomeDirectory()
        let existing = merged["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        merged["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + existing
        return merged
    }

    func run(_ argv: [String], stdin: Data?, env: [String: String]) async -> (status: Int32, stdout: String, stderr: String) {
        let environment = Self.environment(merging: env)
        return await Task.detached(priority: .userInitiated) {
            Self.runBlocking(argv, stdin: stdin, environment: environment)
        }.value
    }

    private static func runBlocking(_ argv: [String], stdin: Data?, environment: [String: String]) -> (status: Int32, stdout: String, stderr: String) {
        guard !argv.isEmpty else { return (127, "", "empty command") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.environment = environment
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try process.run() } catch {
            return (127, "", "could not start \(argv.first ?? ""): \(error.localizedDescription)")
        }
        // Read both pipes to the end on their own threads before waiting: no pipe-full deadlock.
        let group = DispatchGroup()
        let box = Box()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                box.set(data, isOut: isOut)
                group.leave()
            }
        }
        if let stdin {
            // KobeApp.run ignores SIGPIPE at launch; this also covers a child that never reads stdin elsewhere.
            _ = fcntl(inp.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? inp.fileHandleForWriting.write(contentsOf: stdin)
            try? inp.fileHandleForWriting.close()
        }
        group.wait()
        process.waitUntilExit()
        let (o, e) = box.get()
        return (process.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func set(_ d: Data, isOut: Bool) { lock.withLock { if isOut { out = d } else { err = d } } }
        func get() -> (Data, Data) { lock.withLock { (out, err) } }
    }

    func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    /// A symlinked target (dotfiles) is written through: the link stays and the real file gets the bytes. The temp
    /// file is created exclusively with the final mode (`O_CREAT|O_EXCL`, then `fchmod` past the umask), so the bytes
    /// are never readable wider, then renamed over the real file.
    func write(_ path: String, _ text: String, mode: Int16) throws {
        let target = Self.resolvingSymlinks(path)
        let temp = target + ".\(UUID().uuidString).tmp"
        let fd = open(temp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(mode))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            if fchmod(fd, mode_t(mode)) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            if rename(temp, target) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temp)
            throw error
        }
    }

    /// Follows a chain of symlinks (relative ones from the link's folder), at most 16 deep.
    static func resolvingSymlinks(_ path: String) -> String {
        var current = path
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { return current }
            current = destination.hasPrefix("/") ? destination
                : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        }
        return current
    }

    func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func list(_ dir: String) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] }

    func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func remove(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }
}
