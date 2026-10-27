import Foundation
import Observation
import KobeKit

/// GitHub. Three polls, each re-reading the token on every tick:
/// - stats (stars, repos): first after 7 s, then every 5 min;
/// - pulse (your PRs and their checks, default-branch CI, review requests): first after 10 s, then 60 s while
///   anything is running, else 5 min; the card refreshes it when it opens and it's older than 60 s;
/// - activity (contribution calendar): first after 15 s, then every 30 min; the Activity page refreshes it when
///   it's older than 5 min.
/// A token change bumps a generation counter: answers for the old token are dropped. Read-only, api.github.com only.
@MainActor
@Observable
final class GitHubService: ConnectionService {
    @ObservationIgnored let keys: ServiceKeys
    @ObservationIgnored let report: (ServiceEvent) -> Void
    @ObservationIgnored private let session: URLSession

    private(set) var pulse: GitHubPulse?
    private(set) var activity: GitHubActivity?
    private(set) var stats: GitHubStats?
    /// The last pulse poll failed (bad token, offline, GitHub error); cleared by the next good one.
    private(set) var error: ServiceError?
    /// Mirrors the Keychain so views and the pill update when the token is saved or removed.
    private(set) var hasToken: Bool

    @ObservationIgnored private var statsLoop: Task<Void, Never>?
    @ObservationIgnored private var nextPulse: Task<Void, Never>?
    @ObservationIgnored private var nextActivity: Task<Void, Never>?
    @ObservationIgnored private var pulseInFlight = false
    @ObservationIgnored private var activityInFlight = false
    @ObservationIgnored private var generation = 0

    init(keys: ServiceKeys, report: @escaping (ServiceEvent) -> Void, session: URLSession = .kobeEphemeral) {
        self.keys = keys
        self.report = report
        self.session = session
        hasToken = keys.isSet(.github)
    }

    var pillStatus: ConnectionItem.Status {
        if !hasToken { return .notSetUp }
        return error == nil ? .connected : .problem
    }

    var pillDetail: String { "Pull requests" }

    func start() {
        guard statsLoop == nil else { return }
        statsLoop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(GitHubSchedule.statsFirst))
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollStats()
                try? await Task.sleep(for: .seconds(GitHubSchedule.statsEvery))
            }
        }
        schedulePulse(after: GitHubSchedule.pulseFirst)
        scheduleActivity(after: GitHubSchedule.activityFirst)
    }

    func stop() {
        statsLoop?.cancel()
        nextPulse?.cancel()
        nextActivity?.cancel()
        statsLoop = nil
        nextPulse = nil
        nextActivity = nil
        generation += 1
    }

    /// On a token change: forget the old account's pulse and activity (and stats when the token is gone), then
    /// fetch now. Returns nil when the new token works, else the message to show in Settings.
    func keyChanged() async -> String? {
        generation += 1
        hasToken = keys.isSet(.github)
        pulse = nil
        activity = nil
        error = nil
        pulseInFlight = false
        activityInFlight = false
        nextPulse?.cancel()
        nextActivity?.cancel()
        guard hasToken else {
            stats = nil
            schedulePulse(after: GitHubSchedule.nextPulse(hasPending: false))
            scheduleActivity(after: GitHubSchedule.activityEvery)
            return nil
        }
        Task { await pollStats() }
        Task { await pollActivity() }
        return await pollPulse()?.message
    }

    /// Settings' "Refresh": the pulse and the calendar now, whatever their age.
    func refresh() {
        refreshIfStale(maxAge: 0)
        refreshActivityIfStale(maxAge: 0)
    }

    /// The card opened: refresh the pulse now if it's older than 60 s (nothing when a poll is running).
    func refreshIfStale(maxAge: TimeInterval = GitHubSchedule.pulseMaxAge) {
        guard hasToken, !pulseInFlight, GitHubPulse.isStale(fetchedAt: pulse?.fetchedAt, maxAge: maxAge) else { return }
        nextPulse?.cancel()
        nextPulse = Task { [weak self] in await self?.pollPulse() }
    }

    /// The Activity page opened: refresh the calendar now if it's older than 5 min.
    func refreshActivityIfStale(maxAge: TimeInterval = GitHubSchedule.activityMaxAge) {
        guard hasToken, !activityInFlight, GitHubPulse.isStale(fetchedAt: activity?.fetchedAt, maxAge: maxAge) else { return }
        nextActivity?.cancel()
        nextActivity = Task { [weak self] in await self?.pollActivity() }
    }

    // MARK: Polls

    private func client() -> GitHubClient? {
        keys.load(.github).map { GitHubClient(token: $0, session: session) }
    }

    private func pollStats() async {
        guard let client = client() else { return }
        let gen = generation
        guard let fresh = try? await client.stats(), gen == generation else { return }
        stats = fresh
    }

    /// One pulse poll; schedules the next one. Returns the error when it failed.
    @discardableResult
    private func pollPulse() async -> ServiceError? {
        guard !pulseInFlight else { return nil }
        defer { writeSnapshot() }
        guard let client = client() else {
            schedulePulse(after: GitHubSchedule.nextPulse(hasPending: false))
            return nil
        }
        pulseInFlight = true
        let gen = generation
        let result: Result<GitHubPulse, ServiceError>
        do {
            result = .success(try await client.pulse())
        } catch {
            result = .failure(error as? ServiceError ?? .offline)
        }
        // A newer token took over while this was in flight: its own poll owns the state and the schedule.
        guard gen == generation else { return nil }
        pulseInFlight = false
        switch result {
        case .success(let fresh):
            let events = GitHubPulse.events(old: pulse, new: fresh)
            pulse = fresh
            error = nil
            if let event = GitHubPulse.serviceEvent(for: events, in: fresh) { report(event) }
            schedulePulse(after: GitHubSchedule.nextPulse(hasPending: fresh.hasPending))
            return nil
        case .failure(let failure):
            error = failure
            schedulePulse(after: GitHubSchedule.nextPulse(hasPending: false))
            return failure
        }
    }

    private func pollActivity() async {
        guard !activityInFlight else { return }
        defer { writeSnapshot() }
        guard let client = client() else {
            scheduleActivity(after: GitHubSchedule.activityEvery)
            return
        }
        activityInFlight = true
        let gen = generation
        let fresh = try? await client.activity()
        guard gen == generation else { return }
        activityInFlight = false
        if let fresh { activity = fresh }
        scheduleActivity(after: GitHubSchedule.activityEvery)
    }

    func writeSnapshot() {
        guard hasToken else { return SnapshotWriter.write(SnapshotBuilders.notSetUp(.github)) }
        guard pulse != nil || error != nil else { return }
        SnapshotWriter.write(SnapshotBuilders.github(pulse: pulse, activity: activity, stats: stats, error: error?.message))
    }

    private func schedulePulse(after delay: TimeInterval) {
        nextPulse?.cancel()
        nextPulse = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.pollPulse()
        }
    }

    private func scheduleActivity(after delay: TimeInterval) {
        nextActivity?.cancel()
        nextActivity = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.pollActivity()
        }
    }
}
