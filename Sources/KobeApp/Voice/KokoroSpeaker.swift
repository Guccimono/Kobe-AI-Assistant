@preconcurrency import AVFoundation
import Foundation
import KobeKit

/// Local neural speech: Kokoro-82M through the `tts-kokoro` Python helper (kokoro-onnx), one JSON line per request
/// over stdio. Ported from the old Kobe. Everything lives in Kobe's own folder: the helper and its Python
/// environment in ~/Library/Application Support/Kobe/tts-kokoro, the model in …/Kobe/kokoro
/// (scripts/setup-kokoro.sh sets them up). Speaking never touches the network. Sentences are synthesized in order and scheduled back to back on an
/// AVAudioPlayerNode, so playback is gapless and starts with the first sentence. Fully offline.
@MainActor
final class KokoroSpeaker {
    public enum Status: Equatable, Sendable {
        case notStarted
        case starting
        case ready(modelPresent: Bool)
        case failed(String)
    }

    public private(set) var status: Status = .notStarted
    public private(set) var voices: [String] = []
    /// The English voice the user picked. Spanish and French use Kokoro's own voices for them.
    public var voice: String
    public var speed: Double = 1.0
    /// The language replies are in now.
    public var language = "en-US"

    /// Kokoro's voice and espeak language for a language, or nil when Kokoro has no voice for it (the macOS voice
    /// speaks instead). Kokoro-82M v1.0: Spanish ef_dora, em_alex, em_santa; French ff_siwis.
    nonisolated public static func voice(for language: String, english: String) -> (voice: String, lang: String)? {
        switch language.prefix(2).lowercased() {
        case "en": (english, english.hasPrefix("b") ? "en-gb" : "en-us")
        case "es": ("ef_dora", "es")
        case "fr": ("ff_siwis", "fr-fr")
        default: nil
        }
    }

    public var speaksCurrentLanguage: Bool { Self.voice(for: language, english: voice) != nil }

    public static let defaultVoice = "af_heart"
    nonisolated public static let modelDirectory = URL.applicationSupportDirectory.appending(path: "\(Brand.dataFolderName)/kokoro")
    nonisolated static let helperDirectory = URL.applicationSupportDirectory.appending(path: "\(Brand.dataFolderName)/tts-kokoro", directoryHint: .isDirectory)

    nonisolated static var uvPath: String? {
        ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", URL.homeDirectory.appending(path: ".local/bin/uv").path(percentEncoded: false)]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The helper, its Python environment and the model are all on this Mac.
    nonisolated static var isInstalled: Bool {
        modelIsPresent && FileManager.default.fileExists(atPath: helperDirectory.appending(path: ".venv").path(percentEncoded: false))
    }
    nonisolated public static var modelIsPresent: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.appending(path: "kokoro-v1.0.onnx").path)
            && FileManager.default.fileExists(atPath: modelDirectory.appending(path: "voices-v1.0.bin").path)
    }

    private let projectDirectory: String
    private let logURL: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var readTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<ServerReply, Error>] = [:]
    private var nextID = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var generation = 0
    private var queue: Task<Void, Never>?

    public init(
        projectDirectory: String = KokoroSpeaker.helperDirectory.path(percentEncoded: false),
        voice: String = KokoroSpeaker.defaultVoice,
        logURL: URL = URL.libraryDirectory.appending(path: "Logs/\(Brand.dataFolderName)/tts.log")
    ) {
        self.projectDirectory = projectDirectory
        self.voice = voice
        self.logURL = logURL
    }

    // MARK: Server

    /// Starts the Python server and asks it whether the model is installed. Safe to call again.
    public func start() async {
        guard process == nil else { return }
        status = .starting
        do {
            try launch()
            let ping = try await request(["op": "ping"])
            let present = ping.model_present ?? false
            status = .ready(modelPresent: present)
            if present, let list = try? await request(["op": "voices"]).voices {
                voices = list
                if !list.contains(voice) { voice = list.contains(Self.defaultVoice) ? Self.defaultVoice : (list.first ?? voice) }
            }
        } catch {
            status = .failed(error.localizedDescription)
            shutdown()
        }
    }

    public func shutdown() {
        readTask?.cancel()
        readTask = nil
        process?.terminate()
        process = nil
        stdin = nil
        for continuation in pending.values { continuation.resume(throwing: KokoroError.serverStopped) }
        pending.removeAll()
    }

    public var isUsable: Bool {
        if case .ready(let present) = status { return present }
        return false
    }

    private func launch() throws {
        let process = Process()
        guard let uv = Self.uvPath else { throw KokoroError.uvMissing }
        let project = projectDirectory.hasSuffix("/") ? String(projectDirectory.dropLast()) : projectDirectory
        guard FileManager.default.fileExists(atPath: project + "/server.py") else { throw KokoroError.projectMissing(project) }
        process.executableURL = URL(filePath: uv)
        // --offline: packages were installed by KokoroInstaller; speaking never touches the network.
        process.arguments = ["run", "--offline", "--project", project, "python", project + "/server.py"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["KOBE_KOKORO_DIR"] = Self.modelDirectory.path
        process.environment = env

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let log = try? FileHandle(forWritingTo: logURL) {
            _ = try? log.seekToEnd()
            process.standardError = log
        }
        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting

        let reader = output.fileHandleForReading
        readTask = Task.detached { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    await self?.received(Data(line))
                }
            }
            await self?.serverEnded()
        }
    }

    private func received(_ line: Data) {
        guard let reply = try? JSONDecoder().decode(ServerReply.self, from: line),
              let id = reply.id, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = reply.error {
            continuation.resume(throwing: KokoroError.server(error))
        } else {
            continuation.resume(returning: reply)
        }
    }

    private func serverEnded() {
        guard process != nil else { return }
        status = .failed("The speech helper stopped. See ~/Library/Logs/Kobe/tts.log.")
        shutdown()
    }

    private func request(_ fields: [String: Any], timeout: Duration = .seconds(60)) async throws -> ServerReply {
        guard let stdin else { throw KokoroError.serverStopped }
        nextID += 1
        let id = String(nextID)
        var payload = fields
        payload["id"] = id
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = data + Data([0x0A])
        let reply: ServerReply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try stdin.write(contentsOf: line) } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.pending.removeValue(forKey: id)?.resume(throwing: KokoroError.timedOut)
            }
        }
        return reply
    }

    // MARK: Speaking

    public func speak(_ text: String) {
        let generation = self.generation
        guard let (voice, lang) = Self.voice(for: language, english: self.voice) else { return }
        let speed = self.speed
        let previous = queue
        // Synthesis runs in order; each sentence is scheduled as soon as its WAV exists, so the
        // player node plays them back to back while the next one is still being made.
        queue = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == generation else { return }
            do {
                let reply = try await self.request(["text": text, "voice": voice, "speed": speed, "lang": lang])
                guard self.generation == generation, let path = reply.path else { return }
                try self.play(fileAt: URL(filePath: path), generation: generation)
            } catch {
                self.log("speak failed: \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        generation += 1
        queue?.cancel()
        queue = nil
        player.stop()
        engine.stop()
    }

    public var isSpeaking: Bool { player.isPlaying || (queue.map { !$0.isCancelled } ?? false) }

    private func play(fileAt url: URL, generation: Int) throws {
        let file = try AVAudioFile(forReading: url)
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
        }
        if engine.outputNode.inputFormat(forBus: 0).sampleRate == 0 || !engine.isRunning {
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            try engine.start()
        }
        guard self.generation == generation else { return }
        player.scheduleFile(file, at: nil) { try? FileManager.default.removeItem(at: url) }
        if !player.isPlaying { player.play() }
    }

    private func log(_ message: String) {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\(Date()) app: \(message)\n".utf8))
        }
    }
}

/// One line from the server.
struct ServerReply: Decodable, Sendable {
    let id: String?
    let error: String?
    let path: String?
    let seconds: Double?
    let voices: [String]?
    let ok: Bool?
    let model_present: Bool?
}

public enum KokoroError: Error, LocalizedError, Equatable {
    case uvMissing
    case projectMissing(String)
    case serverStopped
    case timedOut
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .uvMissing: "The neural voice needs uv (brew install uv)."
        case .projectMissing: "Kokoro isn't set up on this Mac (scripts/setup-kokoro.sh)."
        case .serverStopped: "The speech server is not running."
        case .timedOut: "The speech server did not answer in time."
        case .server(let message): message
        }
    }
}

/// Routes speech to Kokoro when it is selected and usable, else to the system voice.
