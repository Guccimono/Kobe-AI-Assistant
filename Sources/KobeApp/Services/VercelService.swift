import Foundation
import Observation
import KobeKit

/// Vercel: first check 5 s after launch, then every 30 s, while a token
/// exists. The card lists the last finished deployments of every project; the project filter only decides which
/// ones badge the pill and play a sound.
@MainActor
@Observable
final class VercelService: ConnectionService {
    @ObservationIgnored let keys: ServiceKeys
    @ObservationIgnored let report: (ServiceEvent) -> Void
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var watcher = VercelWatcher()
    /// Bumped on every token change, so an answer for the old token is dropped.
    @ObservationIgnored private var generation = 0

    /// Whether a token is stored (observable copy of the Keychain state, refreshed on every change and poll).
    private(set) var hasToken: Bool
    /// The last finished deployments (up to 5), newest first, all projects.
    private(set) var deployments: [VercelDeployment] = []
    /// The last poll's failure, shown on the pill and the card; nil when it worked.
    private(set) var error: String?
    /// Project names for the Settings filter, once loaded.
    private(set) var projects: [String] = []
    private(set) var loadingProjects = false
    /// Settings' note under the filter ("Save Vercel token first.", "No Vercel projects found.").
    private(set) var projectsMessage: String?
    /// Watched projects for notifications; empty = all.
    var projectFilter: Set<String> {
        didSet { if projectFilter != oldValue { VercelProjectFilter.save(projectFilter) } }
    }

    init(keys: ServiceKeys, report: @escaping (ServiceEvent) -> Void) {
        self.keys = keys
        self.report = report
        self.hasToken = keys.isSet(.vercel)
        self.projectFilter = VercelProjectFilter.load()
    }

    var pillStatus: ConnectionItem.Status {
        guard hasToken else { return .notSetUp }
        return error == nil ? .connected : .problem
    }

    var pillDetail: String { "Deployments" }

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func keyChanged() async -> String? {
        generation += 1
        watcher.reset()
        deployments = []
        error = nil
        projects = []
        projectsMessage = nil
        hasToken = keys.isSet(.vercel)
        guard hasToken else { return nil }
        await poll()
        return error
    }

    func refresh() {
        Task { await poll() }
    }

    /// One check. Without a token it does nothing, so a token added later starts working on the next tick.
    private func poll() async {
        defer { writeSnapshot() }
        let token = keys.load(.vercel)
        if hasToken != (token != nil) { hasToken = token != nil }
        guard let token else { return }
        let started = generation
        do {
            let fresh = try await VercelClient(token: token).deployments()
            guard started == generation else { return }
            if error != nil { error = nil }
            // Keep the previous list while nothing has finished.
            guard !fresh.isEmpty else { return }
            if deployments != fresh { deployments = fresh }
            if let event = watcher.update(fresh, filter: projectFilter) { report(event) }
        } catch {
            guard started == generation else { return }
            let message = (error as? ServiceError)?.message ?? ServiceError.offline.message
            if self.error != message { self.error = message }
        }
    }

    func writeSnapshot() {
        guard hasToken else { return SnapshotWriter.write(SnapshotBuilders.notSetUp(.vercel)) }
        guard !deployments.isEmpty || error != nil else { return }
        SnapshotWriter.write(SnapshotBuilders.vercel(deployments: deployments, error: error))
    }

    /// Settings' "Load list" / "Refresh": every project name, for the filter.
    func loadProjects() async {
        guard let token = keys.load(.vercel) else {
            projectsMessage = "Save Vercel token first."
            return
        }
        loadingProjects = true
        projectsMessage = nil
        defer { loadingProjects = false }
        let started = generation
        do {
            let names = try await VercelClient(token: token).projects()
            guard started == generation else { return }   // the token changed meanwhile
            projects = names
            if names.isEmpty { projectsMessage = "No Vercel projects found." }
        } catch {
            guard started == generation else { return }
            projects = []
            projectsMessage = (error as? ServiceError)?.message ?? "No Vercel projects found."
        }
    }
}
