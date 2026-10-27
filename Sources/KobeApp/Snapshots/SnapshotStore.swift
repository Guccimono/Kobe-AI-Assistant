import Foundation
import Observation
import KobeKit

/// What the pages draw from: the latest snapshot of each connection, read from `widgets/`. One kernel watch on the
/// folder (no timer, no polling): the agent and the shim write by rename, which changes the folder, so every new
/// file wakes it; changes are batched for 150 ms, then only the files whose date or size moved are read again.
@MainActor
@Observable
final class SnapshotStore {
    private(set) var stripe: WidgetSnapshot<StripeSnapshotData>?
    private(set) var whatsapp: WidgetSnapshot<WhatsAppSnapshotData>?
    private(set) var github: WidgetSnapshot<GitHubSnapshotData>?
    private(set) var vercel: WidgetSnapshot<VercelSnapshotData>?
    private(set) var google: WidgetSnapshot<GoogleSnapshotData>?
    private(set) var now: WidgetSnapshot<NowSnapshotData>?
    private(set) var work: WidgetSnapshot<WorkSnapshotData>?
    private(set) var mail: WidgetSnapshot<MailSnapshotData>?
    private(set) var agenda: WidgetSnapshot<AgendaSnapshotData>?
    private(set) var reminders: WidgetSnapshot<RemindersSnapshotData>?
    private(set) var notes: WidgetSnapshot<NotesSnapshotData>?
    /// Every file's envelope (status, headline, detail, date), for every id: also the pages without a typed
    /// property yet, and the `not_set_up` files whose `data` is empty (their typed property is nil).
    private(set) var envelopes: [WidgetID: WidgetSnapshot<EmptyData>] = [:]
    /// A file that didn't decode: the last good snapshot stays, with "couldn't read at 14:28".
    private(set) var readErrors: [WidgetID: String] = [:]

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    /// Modification date and size last read, per file.
    @ObservationIgnored private var seen: [WidgetID: (Date, Int)] = [:]

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// nil: `SnapshotFolder.root`, read each time (the real folder, or `KOBE_EXCHANGE_ROOT`). The tests pass a temp
    /// folder.
    @ObservationIgnored private let root: URL?

    nonisolated init(root: URL? = nil) { self.root = root }

    private var widgetsFolder: URL { root.map(SnapshotFolder.widgets(in:)) ?? SnapshotFolder.widgets }
    private func fileURL(_ id: WidgetID) -> URL { root.map { SnapshotFolder.url(id, in: $0) } ?? SnapshotFolder.url(id) }

    /// Reads every file once, then watches the folder.
    func start() {
        guard source == nil else { return }
        reload()
        watch()
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
    }

    /// The folder moved: watch the new one and read it from scratch.
    func restart() {
        stop()
        seen = [:]
        start()
    }

    func freshness(_ id: WidgetID) -> Freshness {
        SnapshotRules.freshness(updatedAt: envelopes[id]?.updatedAt, schedule: SnapshotRules.schedule(for: id))
    }

    // MARK: Watching

    private func watch() {
        let folder = widgetsFolder
        // The folder must exist to be opened: created like `writeAtomically` creates it (2770, shared with Kobe Agent).
        SnapshotFolder.prepare(folder)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                // The folder itself went away or was renamed: watch the new one at the same path.
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    self.stop()
                    self.seen = [:]
                    self.start()
                } else {
                    self.scheduleReload()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private func scheduleReload() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    // MARK: Reading

    private func reload() {
        let fm = FileManager.default
        for id in WidgetID.allCases {
            let url = fileURL(id)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let date = attributes[.modificationDate] as? Date,
                  let size = (attributes[.size] as? NSNumber)?.intValue else {
                if seen[id] != nil { forget(id) }
                continue
            }
            if let last = seen[id], last == (date, size) { continue }
            seen[id] = (date, size)
            guard let data = try? Data(contentsOf: url) else { failed(id); continue }
            read(id, data)
        }
    }

    private func read(_ id: WidgetID, _ data: Data) {
        guard let envelope = SnapshotDecode.decode(data, as: EmptyData.self), envelope.id == id else {
            failed(id)
            return
        }
        // Not set up: no `data` to show, and an older snapshot's data must not linger.
        let typed: Bool = switch id {
        case .stripe: assign(data, \.stripe, notSetUp: envelope.status == .notSetUp)
        case .whatsapp: assign(data, \.whatsapp, notSetUp: envelope.status == .notSetUp)
        case .github: assign(data, \.github, notSetUp: envelope.status == .notSetUp)
        case .vercel: assign(data, \.vercel, notSetUp: envelope.status == .notSetUp)
        case .google: assign(data, \.google, notSetUp: envelope.status == .notSetUp)
        case .now: assign(data, \.now, notSetUp: envelope.status == .notSetUp)
        case .work: assign(data, \.work, notSetUp: envelope.status == .notSetUp)
        case .mail: assign(data, \.mail, notSetUp: envelope.status == .notSetUp)
        case .agenda: assign(data, \.agenda, notSetUp: envelope.status == .notSetUp)
        case .reminders: assign(data, \.reminders, notSetUp: envelope.status == .notSetUp)
        case .notes: assign(data, \.notes, notSetUp: envelope.status == .notSetUp)
        default: true
        }
        guard typed else {
            failed(id)
            return
        }
        envelopes[id] = envelope
        readErrors[id] = nil
    }

    /// False when the file's `data` doesn't fit the page (the last good snapshot stays).
    private func assign<D>(_ data: Data, _ keyPath: ReferenceWritableKeyPath<SnapshotStore, WidgetSnapshot<D>?>,
                           notSetUp: Bool) -> Bool {
        if notSetUp {
            self[keyPath: keyPath] = nil
            return true
        }
        guard let snapshot = SnapshotDecode.decode(data, as: D.self) else { return false }
        if self[keyPath: keyPath] != snapshot { self[keyPath: keyPath] = snapshot }
        return true
    }

    private func failed(_ id: WidgetID) {
        readErrors[id] = "couldn't read at \(Self.clock.string(from: .now))"
    }

    /// The file was removed: nothing to show for it any more.
    private func forget(_ id: WidgetID) {
        seen[id] = nil
        envelopes[id] = nil
        readErrors[id] = nil
        switch id {
        case .stripe: stripe = nil
        case .whatsapp: whatsapp = nil
        case .github: github = nil
        case .vercel: vercel = nil
        case .google: google = nil
        case .now: now = nil
        case .work: work = nil
        case .mail: mail = nil
        case .agenda: agenda = nil
        case .reminders: reminders = nil
        case .notes: notes = nil
        default: break
        }
    }
}
