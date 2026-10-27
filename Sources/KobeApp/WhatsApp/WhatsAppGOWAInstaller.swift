import Foundation
import Observation
import KobeKit

/// "Install WhatsApp": one click instead of GitHub, a zip, xattr, chmod and a Terminal command.
/// Downloads GOWA's own latest macOS build for this Mac from its GitHub releases, checks its SHA-256 against the
/// checksums GOWA publishes, puts the binary in Kobe's GOWA folder (next to the WhatsApp session it keeps)
/// and turns on "Start GOWA automatically". The only network call is to GitHub, after the click; no message ever
/// goes there.
@MainActor
@Observable
final class WhatsAppGOWAInstaller {
    enum Step: Equatable {
        case idle
        case checking
        case downloading(megabytes: Int)
        case verifying
        case installing
        case done(version: String)
        case failed(String)
    }

    private(set) var step: Step = .idle

    @ObservationIgnored private let settings: WhatsAppSettings
    /// Called once the new binary is in place (the controller starts it; the QR follows).
    @ObservationIgnored var onInstalled: (() -> Void)?

    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: GitHubOnly(), delegateQueue: nil)
    }()

    init(settings: WhatsAppSettings) {
        self.settings = settings
    }

    var busy: Bool {
        switch step {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    func install() {
        guard !busy else { return }
        step = .checking
        Task { await run() }
    }

    private struct Failure: Error, Sendable { let message: String; init(_ m: String) { message = m } }

    private func run() async {
        do {
            // 1. Which build: GOWA's latest release, the zip for this Mac.
            var req = URLRequest(url: WAGOWARelease.latestURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (meta, metaResponse) = try await session.data(for: req)
            guard (metaResponse as? HTTPURLResponse)?.statusCode == 200,
                  let release = WAGOWARelease.parse(meta),
                  let picked = WAGOWARelease.pick(release.assets, arch: WAGOWARelease.arch) else {
                throw Failure(WAText.installNoBuild)
            }
            // The release's own links must point at GitHub over https too, not only the redirects.
            guard Self.isGitHub(picked.zip.url), picked.checksums.map({ Self.isGitHub($0.url) }) ?? true else {
                throw Failure(WAText.installNoBuild)
            }
            var checksums: String?
            if let sums = picked.checksums {
                let (data, response) = try await session.data(from: sums.url)
                if (response as? HTTPURLResponse)?.statusCode == 200 { checksums = String(data: data, encoding: .utf8) }
            }
            guard let expected = WAGOWARelease.expectedSHA256(for: picked.zip, checksums: checksums) else {
                throw Failure(WAText.installNoChecksum)
            }

            // 2. Download.
            step = .downloading(megabytes: max(1, picked.zip.size / 1_000_000))
            let (tmp, zipResponse) = try await session.download(from: picked.zip.url)
            guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(WAText.installDownloadFailed) }

            // 3. Verify: exactly the file GOWA published.
            step = .verifying
            let digest = try await Task.detached { () throws -> String in
                WAGOWARelease.sha256(try Data(contentsOf: tmp))
            }.value
            guard digest == expected else {
                try? FileManager.default.removeItem(at: tmp)
                throw Failure(WAText.installBadChecksum)
            }

            // 4. Unzip with macOS's own ditto, put the binary in place, make it runnable.
            step = .installing
            let binary = WAGOWARelease.binaryName(arch: WAGOWARelease.arch)
            let folder = settings.folder
            try await Task.detached {
                try Self.unpack(zip: tmp, binaryName: binary, into: folder)
            }.value
            settings.installedVersion = release.version
            settings.gateway = .gowa
            settings.setSecret(WhatsAppSettings.urlKey, nil)   // back to http://127.0.0.1:47840
            settings.binaryPath = settings.defaultBinary.path
            settings.autoStart = true
            onInstalled?()
            step = .done(version: release.version)
        } catch let failure as Failure {
            step = .failed(failure.message)
        } catch {
            step = .failed(WAText.installDownloadFailed)
        }
    }

    /// Unzips into a temporary folder, then moves `binaryName` to the GOWA folder as `gowa` (mode 755, no quarantine).
    nonisolated private static func unpack(zip: URL, binaryName: String, into folder: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("kobe-gowa-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); try? fm.removeItem(at: zip) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, work.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure(WAText.installUnzipFailed) }

        guard let found = fm.enumerator(at: work, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == binaryName }) else {
            throw Failure(WAText.installNoBuild)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("gowa")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: found, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        // Downloaded by Kobe itself, it carries no quarantine; cleared anyway so macOS never asks to allow it.
        removexattr(dest.path, "com.apple.quarantine", 0)
    }

    static func isGitHub(_ url: URL) -> Bool { url.scheme == "https" && WAGOWARelease.allowedHost(url.host) }
}

/// The download follows GitHub's redirect to its asset storage, and nothing else.
private final class GitHubOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && WAGOWARelease.allowedHost(request.url?.host) ? request : nil)
    }
}
