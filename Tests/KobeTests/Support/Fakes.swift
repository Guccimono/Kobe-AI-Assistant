import AppKit
import Foundation
@testable import KobeApp
@testable import KobeKit

/// A scripted Hermes for the app's tests: replays one fixed turn, never touches the network. A trimmed copy of
/// KobeKitTests' `FakeHermes` (test targets can't share files).
final class FakeHermes: HermesAPI, @unchecked Sendable {
    var turn: [ChatEvent] = [.started(runID: "run_1"), .delta("Hel"), .delta("lo"), .completed(content: "Hello", model: "m1"), .done]
    /// The stream stays open after `turn` (a turn waiting on an approval).
    var holdsOpen = false

    /// The system prompt of each session made through `createSession(title:systemPrompt:)`, in order.
    var createdSystemPrompts: [String?] = []
    /// What the engine reads back as `has_system_prompt` for a session created with a prompt.
    var reportsSystemPrompt = true
    private var made: [HermesSession] = []

    func listSessions(limit: Int) async throws -> [HermesSession] { made }
    func findSession(title: String) async throws -> HermesSession? { made.first { $0.title == title } }
    func createSession(title: String?) async throws -> HermesSession {
        HermesSession(id: "api_new", source: "api_server", model: nil, title: title, lastActive: nil, preview: nil, messageCount: 0)
    }
    func createSession(title: String?, systemPrompt: String?) async throws -> HermesSession {
        createdSystemPrompts.append(systemPrompt)
        let session = HermesSession(id: "api_\(createdSystemPrompts.count)", source: "api_server", model: nil, title: title,
                                    lastActive: nil, preview: nil, messageCount: 0,
                                    hasSystemPrompt: systemPrompt == nil ? false : reportsSystemPrompt)
        made.append(session)
        return session
    }
    func messages(sessionID: String) async throws -> [HermesMessage] { [] }
    func health() async throws -> HermesHealth { HermesHealth(reachable: true, version: "test", platforms: [:]) }
    func approve(runID: String, requestID: String?, choice: ApprovalChoice) async throws {}
    func deleteSession(id: String) async throws {}
    func stream(sessionID: String, message: String) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let events = turn
        let holdsOpen = holdsOpen
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                    await Task.yield()
                }
                if !holdsOpen { continuation.finish() }
            }
        }
    }
}

/// A fresh, empty exchange folder for one test, removed when the test is done with it.
struct TestSnapshotFolder {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kobe-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("widgets"), withIntermediateDirectories: true)
    }

    func write<D>(_ snapshot: WidgetSnapshot<D>) throws {
        try SnapshotFolder.writeAtomically(SnapshotEncode.encode(snapshot),
                                           to: root.appendingPathComponent("widgets/\(snapshot.id.rawValue).json"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// The island's panel without a window: records what the controller asks of it.
@MainActor
final class FakePanel: PanelProtocol {
    var allowsKey: () -> Bool = { false }
    var contentView: NSView?
    var ignoresMouseEvents = true
    var frame: NSRect = .zero
    var isVisible = false
    var isKeyWindow = false
    var firstResponder: NSResponder? { nil }
    private(set) var madeKey = 0

    func setFrame(_ frameRect: NSRect, display flag: Bool) { frame = frameRect }
    func orderFrontRegardless() { isVisible = true }
    func orderOut(_ sender: Any?) { isVisible = false }
    func makeKey() {
        madeKey += 1
        if allowsKey() { isKeyWindow = true }
    }
    func resignKey() { isKeyWindow = false }
}

/// What one test leaves behind: its defaults suite and its exchange folder, both removed by `cleanup()`.
struct TestSandbox {
    let suiteName = "kobe-tests-\(UUID().uuidString)"
    let folder: TestSnapshotFolder

    init(folder: TestSnapshotFolder = TestSnapshotFolder()) { self.folder = folder }

    /// Empties the suite, has cfprefsd write that out, then removes its (now empty) plist and the folder.
    func cleanup() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
        folder.remove()
    }
}

enum TestApp {
    /// Settings in their own defaults suite (never the real app's), silent, voice off, hover without delay.
    @MainActor
    static func settings(suiteName: String) -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        settings.soundOn = false
        settings.voiceOn = false
        settings.hoverDelay = 0
        settings.openOnHover = true
        settings.closeOnLeave = true
        settings.showNotch = true
        return settings
    }

    /// An app model on in-memory secrets, a fake Kobe and a temp exchange folder: no Keychain, network or real
    /// files. `defer { cleanup() }` removes its defaults suite and folder.
    @MainActor
    static func model(api: FakeHermes = FakeHermes(), folder: TestSnapshotFolder = TestSnapshotFolder(),
                      calendar: FakeCalendar = FakeCalendar(), scripts: FakeScripts = FakeScripts(),
                      shell: any ShellRunner = FakeShell(), secrets: any SecretStoring = InMemorySecrets(),
                      session: URLSession? = nil)
        -> (model: AppModel, cleanup: () -> Void) {
        let sandbox = TestSandbox(folder: folder)
        let model = AppModel(settings: settings(suiteName: sandbox.suiteName), secrets: secrets, api: api,
                             snapshotRoot: folder.root, calendar: calendar, scripts: scripts,
                             shell: shell, home: URL(fileURLWithPath: "/fake/home"), session: session)
        return (model, sandbox.cleanup)
    }

    /// Starts a chat turn that stops on an approval for a long command and stays open (Kobe waits).
    @MainActor
    static func approvalWaiting(_ model: AppModel, api: FakeHermes) async -> Bool {
        let request = ApprovalRequest(runID: "run_1", requestID: "r1", command: "rm -rf build && make all", description: nil)
        api.turn = [.started(runID: "run_1"), .approval(request)]
        api.holdsOpen = true
        model.startTracking()
        model.send("Clean the build")
        return await eventually { model.chats.pendingApproval != nil }
    }

    /// Lets the started tasks run to their next suspension (and a debounce of a few ms pass).
    @MainActor
    static func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
        for _ in 0..<50 { await Task.yield() }
    }

    /// Polls the main actor until `condition` holds or `timeout` runs out.
    @MainActor
    static func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// EventKit for the Mac connectors' tests: access, events and reminders set by the test; `changes` yields on `change()`.
@MainActor
final class FakeCalendar: CalendarSource {
    var accessByKind: [MacKind: MacAccess] = [:]
    var grantOnRequest = true
    private(set) var requests: [MacKind] = []
    var calendars: [AgendaCalendar] = [AgendaCalendar(id: "cal", name: "Work", color: "#F4505E")]
    var eventList: [AgendaEvent] = []
    var reminderList: [ReminderItem] = []
    var failSetDone = false
    var lists: [ReminderList] = []
    var defaultList: String?
    var failAdd = false
    private(set) var added: [(draft: ReminderDraft, list: String?)] = []
    private var continuations: [AsyncStream<Void>.Continuation] = []

    func access(_ kind: MacKind) -> MacAccess { accessByKind[kind] ?? .notAsked }

    func requestAccess(_ kind: MacKind) async -> Bool {
        requests.append(kind)
        accessByKind[kind] = grantOnRequest ? .granted : .denied
        return grantOnRequest
    }

    func events(from: Date, to: Date) -> (calendars: [AgendaCalendar], events: [AgendaEvent]) {
        (calendars, eventList.filter { $0.end > from && $0.start < to })
    }

    private(set) var reminderReads = 0
    func reminders() async -> [ReminderItem] { reminderReads += 1; return reminderList }

    func setDone(_ id: String, _ done: Bool) throws {
        if failSetDone { throw CocoaError(.fileWriteUnknown) }
        guard let i = reminderList.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        reminderList[i].completed = done
    }

    func reminderLists() -> (lists: [ReminderList], defaultID: String?) { (lists, defaultList) }

    func addReminder(_ draft: ReminderDraft, list: String?) throws {
        if failAdd { throw CocoaError(.fileWriteUnknown) }
        added.append((draft, list))
        reminderList.append(ReminderItem(id: "new\(added.count)", title: draft.title, list: list ?? "", listColor: "#000000",
                                         due: draft.due, dueHasTime: draft.dueHasTime, completed: false))
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuations.append($0) }
    }

    func change() { continuations.forEach { $0.yield() } }
}

/// Apple Events for the tests: every script source is recorded; `answer` decides what comes back.
final class FakeScripts: ScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [String] = []
    private var _answer: @Sendable (String) -> Result<String, MacReadProblem> = { _ in .success("") }

    var runs: [String] { lock.withLock { _runs } }
    var answer: @Sendable (String) -> Result<String, MacReadProblem> {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    func run(_ source: String) async -> Result<String, MacReadProblem> {
        let answer = lock.withLock { _runs.append(source); return _answer }
        return answer(source)
    }
}

/// The shell and the small file I/O for the tests: answers are scripted per argv prefix (longest wins),
/// every call is recorded with its stdin, files live in memory and remember the mode they were written with.
final class FakeShell: ShellRunner, @unchecked Sendable {
    typealias Answer = (status: Int32, stdout: String, stderr: String)
    private let lock = NSLock()
    private var scripts: [(prefix: [String], answer: Answer)] = []
    private var _calls: [[String]] = []
    private var _stdins: [Data?] = []
    private var _envs: [[String: String]] = []
    private var _files: [String: String] = [:]
    private var _modes: [String: Int16] = [:]
    private var _dirs: Set<String> = []
    private var _dates: [String: Date] = [:]
    private var _unreadable: Set<String> = []

    /// Answer any call whose argv starts with `prefix`. Unscripted calls answer status 0, no output.
    func script(_ prefix: [String], status: Int32 = 0, stdout: String = "", stderr: String = "") {
        lock.withLock { scripts.append((prefix, (status, stdout, stderr))) }
    }

    var calls: [[String]] { lock.withLock { _calls } }
    var stdins: [Data?] { lock.withLock { _stdins } }
    var envs: [[String: String]] { lock.withLock { _envs } }
    var files: [String: String] { lock.withLock { _files } }
    var modes: [String: Int16] { lock.withLock { _modes } }
    var directories: Set<String> { lock.withLock { _dirs } }

    func setFile(_ path: String, _ text: String, modified: Date = Date()) {
        lock.withLock { _files[path] = text; _dates[path] = modified }
    }

    /// Convention for every later task: no secret ever travels in argv. Assert `argvContains("sk-") == false`.
    func argvContains(_ needle: String) -> Bool {
        calls.contains { $0.contains { $0.contains(needle) } }
    }

    func run(_ argv: [String], stdin: Data?, env: [String: String]) async -> (status: Int32, stdout: String, stderr: String) {
        lock.withLock {
            _calls.append(argv); _stdins.append(stdin); _envs.append(env)
            let hit = scripts.filter { argv.starts(with: $0.prefix) }.max { $0.prefix.count < $1.prefix.count }
            return hit?.answer ?? (0, "", "")
        }
    }

    func fileExists(_ path: String) -> Bool { lock.withLock { _files[path] != nil || _dirs.contains(path) } }
    /// `read` answers nil for this path although the file exists.
    func makeUnreadable(_ path: String) { lock.withLock { _ = _unreadable.insert(path) } }
    func read(_ path: String) -> String? { lock.withLock { _unreadable.contains(path) ? nil : _files[path] } }
    func write(_ path: String, _ text: String, mode: Int16) throws {
        lock.withLock { _files[path] = text; _modes[path] = mode; _dates[path] = Date() }
    }
    func mkdir(_ path: String) throws { lock.withLock { _ = _dirs.insert(path) } }
    func list(_ dir: String) -> [String] {
        lock.withLock {
            _files.keys.filter { $0.hasPrefix(dir + "/") && !$0.dropFirst(dir.count + 1).contains("/") }
                .map { String($0.dropFirst(dir.count + 1)) }
        }
    }
    func modified(_ path: String) -> Date? { lock.withLock { _dates[path] } }
    func remove(_ path: String) throws {
        lock.withLock { _files[path] = nil; _modes[path] = nil; _dates[path] = nil; _dirs.remove(path) }
    }
}
