import Foundation
import KobeKit

/// The shim's pen: today's services write what they fetched to `widgets/<id>.json`, atomically, until Kobe Agent
/// writes those files itself. Before each write it reads who wrote the current file: a fresh one from Kobe Agent
/// wins (`Handover`), and the shim writes again once that file goes stale. A failed write never stops a poll; it
/// is only counted.
@MainActor
enum SnapshotWriter {
    /// Writes that failed since launch (folder not writable, disk full).
    private(set) static var failures = 0

    static func write<D>(_ snapshot: WidgetSnapshot<D>) {
        let url = SnapshotFolder.url(snapshot.id)
        let existing = (try? Data(contentsOf: url)).flatMap(SnapshotDecode.header)
        guard Handover.shimMayWrite(existing: existing, id: snapshot.id, status: snapshot.status) else { return }
        do {
            try SnapshotFolder.writeAtomically(SnapshotEncode.encode(snapshot), to: url)
        } catch {
            failures += 1
        }
    }
}
