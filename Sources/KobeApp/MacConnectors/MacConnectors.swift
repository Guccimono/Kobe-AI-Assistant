import AppKit
import Foundation
import KobeKit
import Observation

/// Calendar and Reminders for the controller: EventKit in the app, a fake in the tests.
@MainActor
protocol CalendarSource: AnyObject {
    func access(_ kind: MacKind) -> MacAccess
    func requestAccess(_ kind: MacKind) async -> Bool
    func events(from: Date, to: Date) -> (calendars: [AgendaCalendar], events: [AgendaEvent])
    /// Incomplete reminders, plus the ones completed in the last 10 s.
    func reminders() async -> [ReminderItem]
    func setDone(_ id: String, _ done: Bool) throws
    /// The lists new reminders can go to, and the one Reminders uses by default.
    func reminderLists() -> (lists: [ReminderList], defaultID: String?)
    /// `list` nil: the default list.
    func addReminder(_ draft: ReminderDraft, list: String?) throws
    /// `EKEventStoreChanged`.
    func changes() -> AsyncStream<Void>
}

/// Mail and Notes for the controller: osascript in the app, a fake in the tests.
protocol ScriptRunner: Sendable {
    func run(_ source: String) async -> Result<String, MacReadProblem>
}

/// What the controller hands the writer: typed, so `SnapshotWriter.write` keeps its generic signature.
enum MacSnapshot {
    case mail(WidgetSnapshot<MailSnapshotData>), agenda(WidgetSnapshot<AgendaSnapshotData>)
    case reminders(WidgetSnapshot<RemindersSnapshotData>), notes(WidgetSnapshot<NotesSnapshotData>)
    /// Not set up, or no access with nothing read before.
    case plain(WidgetSnapshot<EmptyData>)
}

/// Kobe App's reader for Mail, Calendar, Reminders and Notes (Kobe Agent can't read them). It writes their
/// snapshots for the pages and for Kobe Agent. Idle cost: Agenda and Reminders wake on EventKit's change, at the
/// next time boundary and hourly; Mail and Notes are polled only while that app runs. It never opens an app
/// unless one of the `open…` methods is called from a click.
@MainActor
@Observable
final class MacConnectors {
    /// What Settings and the pages say under a connection: no access, finish setup, the last read's error.
    private(set) var problem: [MacKind: String] = [:]

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let calendar: any CalendarSource
    @ObservationIgnored private let scripts: any ScriptRunner
    @ObservationIgnored private let isRunning: (String) -> Bool
    @ObservationIgnored private let write: (MacSnapshot) -> Void
    @ObservationIgnored private let lastFile: (WidgetID) -> Data?
    @ObservationIgnored private let open: (URL) -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let watchesWorkspace: Bool
    /// How long a ticked reminder stays in the file (the undo) before the write that drops it.
    @ObservationIgnored private let dropTickedAfter: Duration

    /// The last data written per page, so a refusal or a closed app never blanks the file.
    @ObservationIgnored private var lastMail: MailSnapshotData?
    @ObservationIgnored private var lastNotes: NotesSnapshotData?
    @ObservationIgnored private var lastAgenda: AgendaSnapshotData?
    @ObservationIgnored private var lastReminders: RemindersSnapshotData?
    @ObservationIgnored private var lastRead: [MacKind: Date] = [:]
    /// The "closed" file was written since the last read: once is enough.
    @ObservationIgnored private var closedWritten: Set<MacKind> = []
    @ObservationIgnored private var remindersRead = 0

    @ObservationIgnored private var polls: [MacKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var debounced: Task<Void, Never>?
    @ObservationIgnored private var boundary: Task<Void, Never>?
    @ObservationIgnored private var dropTicked: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let pollInterval: [MacKind: Duration] = [.mail: .seconds(300), .notes: .seconds(900)]

    init(settings: AppSettings, calendar: any CalendarSource, scripts: any ScriptRunner,
         isRunning: @escaping (String) -> Bool, write: @escaping (MacSnapshot) -> Void,
         lastFile: @escaping (WidgetID) -> Data? = { _ in nil },
         open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         debounce: Duration = .seconds(2), watchesWorkspace: Bool = true, dropTickedAfter: Duration = .seconds(11),
         alwaysOn: Bool = false) {
        self.settings = settings
        self.calendar = calendar
        self.scripts = scripts
        self.isRunning = isRunning
        self.write = write
        self.lastFile = lastFile
        self.open = open
        self.debounce = debounce
        self.dropTickedAfter = dropTickedAfter
        self.watchesWorkspace = watchesWorkspace
        self.alwaysOn = alwaysOn
    }

    /// `--demo`: every connection reads (made-up data), whatever Settings says, and Settings is never changed.
    let alwaysOn: Bool
    private func on(_ kind: MacKind) -> Bool { alwaysOn || settings.isOn(kind) }

    // MARK: Start, stop

    func start() {
        seedFromFiles()
        if watchesWorkspace { watchWorkspace() }
        for kind in MacKind.allCases where on(kind) { resume(kind) }
    }

    func stop() {
        polls.values.forEach { $0.cancel() }
        polls = [:]
        [changesTask, debounced, boundary, dropTicked].forEach { $0?.cancel() }
        changesTask = nil; debounced = nil; boundary = nil; dropTicked = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    /// The Settings switch went on: asks macOS (EventKit), or reads at once if the app runs (the first Apple Event
    /// brings up the Automation prompt). Mail and Notes that aren't open wait for "Finish setup".
    func turnedOn(_ kind: MacKind) async {
        guard on(kind) else { return }
        switch kind {
        case .agenda, .reminders:
            if calendar.access(kind) == .notAsked { _ = await calendar.requestAccess(kind) }
            await readNow(kind)
            watchChanges()
        case .mail, .notes:
            await readNow(kind)
        }
    }

    /// The switch went off: the page reads "Not set up" and nothing about that app runs any more.
    func turnedOff(_ kind: MacKind) {
        polls[kind]?.cancel()
        polls[kind] = nil
        problem[kind] = nil
        closedWritten.remove(kind)
        if kind == .reminders {
            // A late write (the dropped tick, a read in flight) must not undo "Not set up".
            dropTicked?.cancel()
            dropTicked = nil
            remindersRead += 1
        }
        if !on(.agenda) && !on(.reminders) {
            [changesTask, debounced, boundary].forEach { $0?.cancel() }
            changesTask = nil; debounced = nil; boundary = nil
        }
        write(.plain(SnapshotBuilders.notSetUp(kind.id)))
    }

    /// ⌘R and opening the page.
    func refresh(_ kind: MacKind) {
        Task { await readNow(kind) }
    }

    /// For Settings: EventKit's answer, or for Mail and Notes whether a read ever worked.
    func access(_ kind: MacKind) -> MacAccess {
        switch kind {
        case .agenda, .reminders: return calendar.access(kind)
        case .mail, .notes:
            if problem[kind] == kind.deniedCopy { return .denied }
            return (kind == .mail ? settings.mailReady : settings.notesReady) ? .granted : .notAsked
        }
    }

    func appRunning(_ kind: MacKind) -> Bool { kind.bundleID.map(isRunning) ?? true }

    // MARK: Reading

    func readNow(_ kind: MacKind) async {
        guard on(kind) else { return }
        switch kind {
        case .agenda: writeAgenda()
        case .reminders: await writeReminders()
        case .mail: await readMail()
        case .notes: await readNotes()
        }
    }

    private func writeAgenda() {
        let now = Date()
        switch calendar.access(.agenda) {
        case .notAsked: return
        case .denied: denied(.agenda); return
        case .granted: break
        }
        let (from, to) = AgendaTime.range(now: now)
        let read = calendar.events(from: from, to: to)
        let snapshot = MacBuilders.agenda(events: read.events, calendars: read.calendars, from: from, to: to, now: now)
        lastAgenda = snapshot.data
        problem[.agenda] = nil
        write(.agenda(snapshot))
        scheduleBoundary()
    }

    private func writeReminders() async {
        switch calendar.access(.reminders) {
        case .notAsked: return
        case .denied: denied(.reminders); return
        case .granted: break
        }
        // Two ticks in a row: only the read that started last may write, so the file ends as the last click.
        remindersRead += 1
        let generation = remindersRead
        let items = await calendar.reminders()
        guard generation == remindersRead, on(.reminders) else { return }
        let snapshot = MacBuilders.reminders(items, now: .now)
        lastReminders = snapshot.data
        problem[.reminders] = nil
        write(.reminders(snapshot))
        scheduleBoundary()
    }

    private func readMail() async {
        guard let bundle = MacKind.mail.bundleID, isRunning(bundle) else { closed(.mail); return }
        let result = await scripts.run(MacScripts.mail)
        guard on(.mail) else { return }
        switch result {
        case .success(let text):
            let now = Date()
            let read = AppleEventsOutput.mailRead(text, now: now)
            let snapshot = MacBuilders.mail(messages: read.messages, unreadTotal: read.unread, appRunning: true,
                                            lastRead: now, now: now)
            self.read(.mail, at: now)
            lastMail = snapshot.data
            write(.mail(snapshot))
        case .failure(let problem):
            failed(.mail, problem)
        }
        startPoll(.mail)
    }

    private func readNotes() async {
        guard let bundle = MacKind.notes.bundleID, isRunning(bundle) else { closed(.notes); return }
        let index: [(id: String, title: String, folder: String, modified: Date)]
        let now = Date()
        switch await scripts.run(MacScripts.notesIndex) {
        case .success(let text): index = AppleEventsOutput.notesIndex(text, now: now)
        case .failure(let problem): failed(.notes, problem); startPoll(.notes); return
        }
        let newest = index.sorted { $0.modified > $1.modified }.prefix(MacBuilders.notesLimit)
        var bodies: [String: String] = [:]
        if !newest.isEmpty {
            switch await scripts.run(MacScripts.notesBody(ids: newest.map(\.id))) {
            case .success(let text): bodies = AppleEventsOutput.notesBodies(text)
            case .failure(let problem): failed(.notes, problem); startPoll(.notes); return
            }
        }
        guard on(.notes) else { return }
        let notes = newest.map { n in
            NoteItem(id: n.id, title: n.title, snippet: bodies[n.id] ?? "", folder: n.folder, modified: n.modified)
        }
        let snapshot = MacBuilders.notes(notes: notes, appRunning: true, lastRead: now, now: now)
        read(.notes, at: now)
        lastNotes = snapshot.data
        write(.notes(snapshot))
        startPoll(.notes)
    }

    /// A read worked: Automation is allowed, setup is finished.
    private func read(_ kind: MacKind, at date: Date) {
        lastRead[kind] = date
        problem[kind] = nil
        closedWritten.remove(kind)
        if kind == .mail { settings.mailReady = true }
        if kind == .notes { settings.notesReady = true }
    }

    private func failed(_ kind: MacKind, _ reason: MacReadProblem) {
        switch reason {
        case .denied: denied(kind)
        case .notRunning: closed(kind)
        case .other(let message): problem[kind] = message
        }
    }

    /// macOS said no: the page and Kobe Agent read how to fix it, over the last good data when there is some.
    private func denied(_ kind: MacKind) {
        problem[kind] = kind.deniedCopy
        let now = Date()
        func keeping<D>(_ data: D) -> WidgetSnapshot<D> {
            WidgetSnapshot(id: kind.id, updatedAt: now, status: .failed, headline: "No access", detail: "",
                           error: kind.deniedCopy, data: data)
        }
        switch kind {
        case .mail: if let d = lastMail { write(.mail(keeping(d))); return }
        case .agenda: if let d = lastAgenda { write(.agenda(keeping(d))); return }
        case .reminders: if let d = lastReminders { write(.reminders(keeping(d))); return }
        case .notes: if let d = lastNotes { write(.notes(keeping(d))); return }
        }
        write(.plain(MacBuilders.denied(kind.id, app: kind.app, now: now)))
    }

    /// Mail or Notes isn't running: the last data once more, saying so, then nothing until it opens.
    private func closed(_ kind: MacKind) {
        polls[kind]?.cancel()
        polls[kind] = nil
        let ready = kind == .mail ? settings.mailReady : settings.notesReady
        if !ready { problem[kind] = kind.finishSetupCopy }
        guard !closedWritten.contains(kind) else { return }
        let now = Date()
        switch kind {
        case .mail:
            guard let d = lastMail else { return }
            write(.mail(MacBuilders.mail(messages: d.messages, unreadTotal: d.unread, appRunning: false,
                                         lastRead: lastRead[.mail], now: now)))
        case .notes:
            guard let d = lastNotes else { return }
            write(.notes(MacBuilders.notes(notes: d.notes, appRunning: false, lastRead: lastRead[.notes], now: now)))
        case .agenda, .reminders: return
        }
        closedWritten.insert(kind)
    }

    // MARK: Ticking reminders

    /// The circle (done) or Undo (not done), from a click only. Written to Reminders at once, then the file.
    func setDone(_ id: String, _ done: Bool) async -> Result<Void, ActionError> {
        guard on(.reminders), calendar.access(.reminders) == .granted else {
            return .failure(ActionError(message: MacKind.reminders.deniedCopy))
        }
        do {
            try calendar.setDone(id, done)
        } catch {
            return .failure(ActionError(message: "Couldn't update the reminder"))
        }
        await writeReminders()
        // A ticked reminder stays in the file for 10 s (the undo); one more write drops it after that.
        dropTicked?.cancel()
        if done {
            dropTicked = Task { [weak self] in
                try? await Task.sleep(for: self?.dropTickedAfter ?? .seconds(11))
                guard !Task.isCancelled else { return }
                await self?.writeReminders()
            }
        }
        return .success(())
    }

    // MARK: Adding reminders

    /// The add field's Return: a click-and-type from the user, written to Reminders at once, then the file.
    func addReminder(_ draft: ReminderDraft, list: String?) async -> Result<Void, ActionError> {
        guard !draft.isEmpty else { return .failure(ActionError(message: "Type the reminder first")) }
        guard on(.reminders), calendar.access(.reminders) == .granted else {
            return .failure(ActionError(message: MacKind.reminders.deniedCopy))
        }
        do {
            try calendar.addReminder(draft, list: list)
        } catch {
            return .failure(ActionError(message: "Couldn't add the reminder"))
        }
        await writeReminders()
        return .success(())
    }

    /// The list chip's choices, Reminders' default first; none while Reminders is off.
    func reminderLists() -> [ReminderList] {
        guard on(.reminders), calendar.access(.reminders) == .granted else { return [] }
        let (lists, defaultID) = calendar.reminderLists()
        return lists.filter { $0.id == defaultID } + lists.filter { $0.id != defaultID }
    }

    // MARK: Editing a note

    /// The note open in the notch's editor; kept here so it survives the notch folding and reopening.
    struct NoteEditing: Equatable {
        let id: String
        var title: String
        /// nil: read-only (`readOnly` says why, or Notes isn't open).
        var document: NoteDocument?
        var readOnly: NoteDocument.ReadOnly?
        var text: String
        var savedText: String
        var modified: Date?
        var problem: String?
        var saving = false

        var dirty: Bool { document != nil && text != savedText }
    }

    var editing: NoteEditing?

    /// A click on a note: read it from Notes (running only; Kobe never opens it) into the editor.
    func editNote(_ id: String, title: String) async {
        editing = NoteEditing(id: id, title: title, text: "", savedText: "")
        guard on(.notes), let bundle = MacKind.notes.bundleID, isRunning(bundle) else {
            editing?.problem = "Open Notes to edit here"
            return
        }
        let result = await scripts.run(MacScripts.noteRead(id: id))
        guard editing?.id == id else { return }
        guard case .success(let text) = result, let note = AppleEventsOutput.noteRead(text, now: .now) else {
            editing?.problem = "Couldn't read the note"
            return
        }
        editing?.modified = note.modified
        switch NoteDocument.parse(html: note.html, attachments: note.attachments, locked: note.locked) {
        case .success(let document):
            editing?.document = document
            editing?.text = document.text
            editing?.savedText = document.text
        case .failure(let reason):
            editing?.readOnly = reason
            editing?.text = note.plain
            editing?.savedText = note.plain
        }
    }

    /// Writes the editor's text to Notes when it changed, never over a note changed in Notes meanwhile.
    @discardableResult
    func saveNote() async -> Bool {
        guard let current = editing, let document = current.document, let modified = current.modified else { return false }
        guard current.dirty else { return true }
        guard let bundle = MacKind.notes.bundleID, isRunning(bundle) else {
            editing?.problem = "Open Notes to save"
            return false
        }
        let text = current.text
        editing?.saving = true
        let result = await scripts.run(MacScripts.noteWrite(id: current.id, html: document.html(from: text),
                                                            modifiedEpoch: Int(modified.timeIntervalSince1970.rounded())))
        guard editing?.id == current.id else { return false }
        editing?.saving = false
        switch result {
        case .success(let answer):
            switch AppleEventsOutput.noteWrite(answer, now: .now) {
            case .saved(let date):
                editing?.savedText = text
                editing?.modified = date
                editing?.problem = nil
                Task { await readNow(.notes) }
                return true
            case .changed: editing?.problem = "Changed in Notes since you opened it: copy your text, then reopen"
            case .locked: editing?.problem = "The note is locked"
            case nil: editing?.problem = "Couldn't save the note"
            }
        case .failure(let problem):
            if case .denied = problem { denied(.notes) }
            editing?.problem = "Couldn't save the note"
        }
        return false
    }

    /// Back to the cards: saves first, and stays open when the save didn't go (the text is never thrown away).
    func closeNote() async {
        if editing?.dirty == true, await !saveNote() { return }
        editing = nil
    }

    /// Back without saving, after a save was refused.
    func discardNote() { editing = nil }

    // MARK: Browsing

    /// A month the page shows outside the snapshot's range: read live, never written.
    func month(_ date: Date) -> (calendars: [AgendaCalendar], events: [AgendaEvent]) {
        guard on(.agenda) else { return ([], []) }
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .month, for: date) else { return ([], []) }
        return calendar.events(from: start.start, to: start.end)
    }

    // MARK: Opening (clicks only)

    func openMail(_ messageID: String) {
        let id = messageID.addingPercentEncoding(withAllowedCharacters: Self.urlSafe) ?? messageID
        if let url = URL(string: "message://%3C\(id)%3E"), open(url) { return }
        openApp("com.apple.mail")
    }

    func openNote(_ id: String) {
        Task { [scripts] in _ = await scripts.run(MacScripts.notesShow(id: id)) }
    }

    func openEvent(_ id: String) {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: Self.urlSafe) ?? id
        if let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"), open(url) { return }
        openApp("com.apple.iCal")
    }

    func openReminders(_ id: String? = nil) {
        if let id, let encoded = id.addingPercentEncoding(withAllowedCharacters: Self.urlSafe),
           let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(encoded)"), open(url) { return }
        openApp("com.apple.reminders")
    }

    /// The footer's "Open Mail" and the like.
    func openApp(_ kind: MacKind) {
        switch kind {
        case .mail: openApp("com.apple.mail")
        case .agenda: openApp("com.apple.iCal")
        case .reminders: openApp("com.apple.reminders")
        case .notes: openApp("com.apple.Notes")
        }
    }

    private func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        _ = open(url)
    }

    /// Letters, digits and the few marks Message-IDs and EventKit ids use; "/" and "?" are encoded.
    private static let urlSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@=+:"))

    // MARK: Timers

    private func resume(_ kind: MacKind) {
        switch kind {
        case .agenda, .reminders:
            Task { await readNow(kind) }
            watchChanges()
        case .mail, .notes:
            if let bundle = kind.bundleID, isRunning(bundle) { Task { await readNow(kind) } } else { closed(kind) }
        }
    }

    /// The next poll of Mail or Notes, replacing any other; only while that app runs.
    private func startPoll(_ kind: MacKind, first: Duration? = nil) {
        guard let interval = Self.pollInterval[kind], on(kind),
              let bundle = kind.bundleID, isRunning(bundle) else { return }
        polls[kind]?.cancel()
        polls[kind] = Task { [weak self] in
            try? await Task.sleep(for: first ?? interval)
            guard !Task.isCancelled else { return }
            await self?.readNow(kind)
        }
    }

    /// EventKit's change, debounced: one rewrite of Agenda and Reminders after the burst.
    private func watchChanges() {
        guard changesTask == nil else { return }
        let stream = calendar.changes()
        changesTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                self.debounced?.cancel()
                self.debounced = Task { [weak self] in
                    try? await Task.sleep(for: self?.debounce ?? .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self?.rewriteCalendar()
                }
            }
        }
    }

    private func rewriteCalendar() async {
        if on(.agenda) { writeAgenda() }
        if on(.reminders) { await writeReminders() }
    }

    /// One sleep to the next moment what Agenda or Reminders says changes (at most an hour: the heartbeat).
    private func scheduleBoundary() {
        boundary?.cancel()
        let now = Date()
        let next = AgendaTime.nextRewrite(now: now, events: lastAgenda?.events ?? [],
                                          reminders: lastReminders?.reminders ?? [])
        boundary = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSince(now), 1)))
            guard !Task.isCancelled else { return }
            await self?.rewriteCalendar()
        }
    }

    // MARK: Mail and Notes opening or quitting

    private func watchWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let id: (Notification) -> String? = {
            ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        }
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let bundle = id(note) else { return }
            MainActor.assumeIsolated { self?.appLaunched(bundle) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let bundle = id(note) else { return }
            MainActor.assumeIsolated { self?.appTerminated(bundle) }
        })
    }

    /// Mail or Notes just opened: read once it has had a few seconds to load its accounts.
    func appLaunched(_ bundleID: String) {
        guard let kind = MacKind.allCases.first(where: { $0.bundleID == bundleID }), on(kind) else { return }
        startPoll(kind, first: .seconds(5))
    }

    func appTerminated(_ bundleID: String) {
        guard let kind = MacKind.allCases.first(where: { $0.bundleID == bundleID }), on(kind) else { return }
        closed(kind)
    }

    /// At launch: what the files already hold, so a closed app or a refusal keeps it.
    private func seedFromFiles() {
        func load<D: Codable & Sendable & Equatable>(_ id: WidgetID, _ type: D.Type) -> WidgetSnapshot<D>? {
            lastFile(id).flatMap { SnapshotDecode.decode($0, as: D.self) }
        }
        if lastMail == nil, let s = load(.mail, MailSnapshotData.self) {
            lastMail = s.data
            lastRead[.mail] = s.data.appRunning ? s.updatedAt : nil
            if !s.data.appRunning { closedWritten.insert(.mail) }
        }
        if lastNotes == nil, let s = load(.notes, NotesSnapshotData.self) {
            lastNotes = s.data
            lastRead[.notes] = s.data.appRunning ? s.updatedAt : nil
            if !s.data.appRunning { closedWritten.insert(.notes) }
        }
        if lastAgenda == nil { lastAgenda = load(.agenda, AgendaSnapshotData.self)?.data }
        if lastReminders == nil { lastReminders = load(.reminders, RemindersSnapshotData.self)?.data }
    }
}
