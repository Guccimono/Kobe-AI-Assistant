import Foundation
import KobeKit

/// What every connection (Stripe, GitHub, Vercel, WhatsApp) gives the rest of the app. Each one polls on its own,
/// and reports what it notices through the `report` closure it was made with.
@MainActor
protocol ConnectionService: AnyObject {
    /// The Home pill's state: connected, a problem, or not set up.
    var pillStatus: ConnectionItem.Status { get }
    /// The pill's one-line detail ("Payments", "Deployments", "Pull requests", "Messages", or a short status).
    var pillDetail: String { get }
    /// Starts background polling (called once at launch). Must do nothing until a key or link exists.
    func start()
    /// Stops every timer, task and process (called at quit).
    func stop()
    /// A key was saved or removed in Settings: fetch now. Returns nil when it worked, else the message to show.
    func keyChanged() async -> String?
    /// Settings' "Refresh": fetch now, keeping what's shown and what was already announced.
    func refresh()
    /// The shim: writes what this connection knows to its snapshot file (`not_set_up` without a key or link).
    /// Skips the write while a key exists but nothing came back yet, so a launch never blanks a good file.
    func writeSnapshot()
}

/// Lets the services be created before AppModel can hand them `self`.
@MainActor
final class ServiceEventSink {
    var handler: ((ServiceEvent) -> Void)?
    nonisolated init() {}
}
