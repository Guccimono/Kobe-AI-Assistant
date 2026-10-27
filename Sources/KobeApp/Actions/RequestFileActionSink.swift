import Foundation
import KobeKit

/// Actions Kobe Agent runs: `requests/<uuid>.json` in, `results/<uuid>.json` back (the agent's daemon answers within
/// a second or two; a connector's own fetch can take ten). Only `refresh` for now. Waits by looking every 250 ms,
/// and only while an answer is due; after `timeout` the request is withdrawn.
@MainActor
final class RequestFileActionSink: ActionSink {
    private let root: URL?
    private let timeout: Duration

    /// nil `root`: `SnapshotFolder.root`, read each time.
    init(root: URL? = nil, timeout: Duration = .seconds(20)) {
        self.root = root
        self.timeout = timeout
    }

    private struct Answer: Decodable { let ok: Bool; let error: String? }

    func perform(_ action: WidgetAction) async -> Result<Void, ActionError> {
        guard case .refresh(let id) = action else { return .failure(ActionError(message: "Kobe Agent doesn't do that yet")) }
        let root = self.root ?? SnapshotFolder.root
        let name = "\(UUID().uuidString.lowercased()).json"
        let request = SnapshotFolder.requests(in: root).appendingPathComponent(name)
        let result = SnapshotFolder.results(in: root).appendingPathComponent(name)
        SnapshotFolder.prepare(SnapshotFolder.results(in: root))
        do {
            let body = try JSONSerialization.data(withJSONObject: ["action": "refresh", "id": id.rawValue], options: [.sortedKeys])
            try SnapshotFolder.writeAtomically(body, to: request)
        } catch {
            return .failure(ActionError(message: "Couldn't reach Kobe Agent's folder"))
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            guard let data = try? Data(contentsOf: result), let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
                continue
            }
            try? FileManager.default.removeItem(at: result)
            return answer.ok ? .success(()) : .failure(ActionError(message: answer.error ?? "Kobe Agent refused"))
        }
        try? FileManager.default.removeItem(at: request)
        return .failure(ActionError(message: "Kobe Agent didn't answer"))
    }
}
