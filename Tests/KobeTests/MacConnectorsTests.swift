import Foundation
import Testing
@testable import KobeApp
@testable import KobeKit

@MainActor
@Suite(.serialized) struct MacConnectorsTests {
    let suite = "kobe-tests-\(UUID().uuidString)"
    let settings: AppSettings
    let calendar = FakeCalendar()
    let scripts = FakeScripts()
    final class Box { var running: Set<String> = []; var writes: [MacSnapshot] = []; var opened: [URL] = [] }
    let box = Box()

    init() { settings = AppSettings(defaults: UserDefaults(suiteName: suite)!) }

    func controller() -> MacConnectors {
        MacConnectors(settings: settings, calendar: calendar, scripts: scripts,
                      isRunning: { [box] in box.running.contains($0) },
                      write: { [box] in box.writes.append($0) },
                      lastFile: { _ in nil },
                      open: { [box] in box.opened.append($0); return true },
                      debounce: .milliseconds(20), watchesWorkspace: false, dropTickedAfter: .milliseconds(60))
    }

    var agendaWrites: [WidgetSnapshot<AgendaSnapshotData>] {
        box.writes.compactMap { if case .agenda(let s) = $0 { s } else { nil } }
    }
    var reminderWrites: [WidgetSnapshot<RemindersSnapshotData>] {
        box.writes.compactMap { if case .reminders(let s) = $0 { s } else { nil } }
    }
    var mailWrites: [WidgetSnapshot<MailSnapshotData>] {
        box.writes.compactMap { if case .mail(let s) = $0 { s } else { nil } }
    }
    var plainWrites: [WidgetSnapshot<EmptyData>] {
        box.writes.compactMap { if case .plain(let s) = $0 { s } else { nil } }
    }

    func mailText(_ id: String = "m1", unread: Bool = true) -> String {
        "#unread\u{1F}1\u{1E}"
            + ["<\(id)@example.com>", "Example Client", "Menu", "-60", unread ? "false" : "true", "Google", "Hi"]
            .joined(separator: "\u{1F}") + "\u{1E}"
    }

    func ok(_ r: Result<Void, ActionError>) -> Bool { if case .success = r { true } else { false } }

    @Test func offWritesNothing() async {
        let mac = controller()
        mac.start()
        await TestApp.settle()
        #expect(box.writes.isEmpty && calendar.requests.isEmpty && scripts.runs.isEmpty)
        mac.stop()
    }

    @Test func turningOnAgendaAsksOnceThenWrites() async {
        calendar.eventList = [AgendaEvent(id: "e1", title: "Call", calendar: "cal", start: .now.addingTimeInterval(600),
                                          end: .now.addingTimeInterval(1800), allDay: false)]
        let mac = controller()
        settings.agendaOn = true
        await mac.turnedOn(.agenda)
        await mac.turnedOn(.agenda)
        #expect(calendar.requests == [.agenda])
        #expect(agendaWrites.count == 2 && agendaWrites[0].data.events.map(\.id) == ["e1"])
        #expect(agendaWrites[0].source == .app && mac.problem[.agenda] == nil)
        mac.stop()
    }

    @Test func deniedWritesNoAccess() async {
        calendar.grantOnRequest = false
        let mac = controller()
        settings.agendaOn = true
        await mac.turnedOn(.agenda)
        #expect(plainWrites.count == 1 && plainWrites[0].status == .failed && plainWrites[0].headline == "No access")
        #expect(mac.problem[.agenda] == "Kobe can't read Calendar: allow it in System Settings › Privacy & Security")
        mac.stop()
    }

    @Test func deniedKeepsTheLastGoodData() async {
        calendar.accessByKind[.agenda] = .granted
        calendar.eventList = [AgendaEvent(id: "e1", title: "Call", calendar: "cal", start: .now, end: .now.addingTimeInterval(60),
                                          allDay: false)]
        let mac = controller()
        settings.agendaOn = true
        await mac.turnedOn(.agenda)
        calendar.accessByKind[.agenda] = .denied
        await mac.readNow(.agenda)
        #expect(agendaWrites.count == 2)
        #expect(agendaWrites[1].status == .failed && agendaWrites[1].data.events.map(\.id) == ["e1"])
        #expect(agendaWrites[1].error?.hasPrefix("Kobe can't read Calendar") == true)
        mac.stop()
    }

    @Test func calendarChangeRewrites() async {
        calendar.accessByKind[.agenda] = .granted
        settings.agendaOn = true
        let mac = controller()
        mac.start()
        #expect(await TestApp.eventually { agendaWrites.count == 1 })
        calendar.change()
        calendar.change()
        #expect(await TestApp.eventually(timeout: .seconds(3)) { agendaWrites.count == 2 })
        await TestApp.settle()
        #expect(agendaWrites.count == 2)
        mac.stop()
    }

    @Test func mailOnlyWhileRunning() async {
        scripts.answer = { [text = mailText()] _ in .success(text) }
        let mac = controller()
        settings.mailOn = true
        await mac.turnedOn(.mail)
        #expect(scripts.runs.isEmpty && mailWrites.isEmpty)
        #expect(mac.problem[.mail] == "Open Mail to finish setup")
        box.running = ["com.apple.mail"]
        await mac.turnedOn(.mail)
        #expect(scripts.runs.count == 1 && mailWrites.count == 1)
        #expect(mailWrites[0].data.messages.map(\.id) == ["m1@example.com"] && mailWrites[0].data.appRunning)
        #expect(mac.problem[.mail] == nil)
        mac.stop()
    }

    @Test func mailQuitWritesClosedOnce() async {
        scripts.answer = { [text = mailText()] _ in .success(text) }
        box.running = ["com.apple.mail"]
        settings.mailOn = true
        let mac = controller()
        await mac.readNow(.mail)
        box.running = []
        mac.appTerminated("com.apple.mail")
        mac.appTerminated("com.apple.mail")
        #expect(mailWrites.count == 2)
        #expect(mailWrites[1].detail.hasPrefix("Mail is closed") && !mailWrites[1].data.appRunning)
        #expect(mailWrites[1].data.messages.map(\.id) == ["m1@example.com"])
        mac.stop()
    }

    @Test func mailFailureKeepsLastFile() async {
        scripts.answer = { _ in .failure(.other("x")) }
        box.running = ["com.apple.mail"]
        settings.mailOn = true
        let mac = controller()
        await mac.readNow(.mail)
        #expect(box.writes.isEmpty && mac.problem[.mail] == "x")
        mac.stop()
    }

    @Test func notesReadsTheIndexThenTheNewestBodies() async {
        let US = "\u{1F}", RS = "\u{1E}"
        scripts.answer = { source in
            if source == MacScripts.notesIndex {
                return .success((0..<15).map { "n\($0)\(US)Note \($0)\(US)Notes\(US)-\($0 * 60)\(RS)" }.joined())
            }
            return .success("n0\(US)Tacos\nFlan\(RS)")
        }
        box.running = ["com.apple.Notes"]
        settings.notesOn = true
        let mac = controller()
        await mac.readNow(.notes)
        #expect(scripts.runs.count == 2)
        #expect(scripts.runs[1].contains("\"n0\"") && scripts.runs[1].contains("\"n11\"") && !scripts.runs[1].contains("\"n12\""))
        let notes = box.writes.compactMap { if case .notes(let s) = $0 { s } else { nil } }
        #expect(notes.count == 1 && notes[0].data.notes.count == 12)
        #expect(notes[0].data.notes[0].folder == "Notes" && notes[0].data.notes[0].snippet == "Tacos\nFlan")
        mac.stop()
    }

    // MARK: Editing a note

    func noteAnswers(locked: Bool = false, attachments: Int = 0, html: String = "<div><h1>Trip</h1></div><div>Pack</div>",
                     write: String = "#saved\u{1F}-1\u{1E}") {
        let US = "\u{1F}", RS = "\u{1E}"
        scripts.answer = { source in
            if source.contains("set body of note") { return .success(write) }
            if source.contains("password protected") {
                return .success("-60\(US)\(locked)\(US)\(attachments)\(US)\(html)\(US)Trip\nPack\(RS)")
            }
            return .success("")
        }
    }

    @Test func editAndSaveANote() async {
        noteAnswers()
        box.running = ["com.apple.Notes"]
        settings.notesOn = true
        let mac = controller()
        await mac.editNote("n1", title: "Trip")
        #expect(mac.editing?.text == "Trip\nPack" && mac.editing?.readOnly == nil && !(mac.editing?.dirty ?? true))
        mac.editing?.text = "Trip\nPack\nPassport"
        #expect(mac.editing?.dirty == true)
        #expect(await mac.saveNote())
        let write = scripts.runs.last { $0.contains("set body of note") } ?? ""
        #expect(write.contains("<div><h1>Trip</h1></div><div>Pack</div><div>Passport</div>"))
        #expect(mac.editing?.dirty == false)
        // Nothing changed: no write.
        let runs = scripts.runs.count
        #expect(await mac.saveNote())
        #expect(scripts.runs.count == runs)
        await mac.closeNote()
        #expect(mac.editing == nil)
        mac.stop()
    }

    @Test func aNoteChangedInNotesIsNeverOverwritten() async {
        noteAnswers(write: "#changed\u{1E}")
        box.running = ["com.apple.Notes"]
        settings.notesOn = true
        let mac = controller()
        await mac.editNote("n1", title: "Trip")
        mac.editing?.text = "Trip\nmine"
        #expect(await mac.saveNote() == false)
        #expect(mac.editing?.problem == "Changed in Notes since you opened it: copy your text, then reopen")
        // Closing keeps the editor open while the text isn't saved.
        await mac.closeNote()
        #expect(mac.editing != nil)
        mac.discardNote()
        #expect(mac.editing == nil)
        mac.stop()
    }

    @Test func richOrClosedNotesAreReadOnly() async {
        noteAnswers(html: "<div>T</div><div>a <b>bold</b> word</div>")
        box.running = ["com.apple.Notes"]
        settings.notesOn = true
        let mac = controller()
        await mac.editNote("n1", title: "T")
        #expect(mac.editing?.readOnly == .formatting && mac.editing?.text == "Trip\nPack")
        mac.editing?.text = "changed"
        #expect(await mac.saveNote() == false)
        #expect(!scripts.runs.contains { $0.contains("set body of note") })
        // Notes closed: nothing is sent, the editor says why.
        box.running = []
        await mac.editNote("n2", title: "Other")
        #expect(mac.editing?.id == "n2" && mac.editing?.problem == "Open Notes to edit here")
        mac.stop()
    }

    @Test func tickAndUndo() async {
        calendar.accessByKind[.reminders] = .granted
        calendar.reminderList = [ReminderItem(id: "r1", title: "Invoice", list: "Work", listColor: "#F5A524", due: nil,
                                              dueHasTime: false, completed: false)]
        settings.remindersOn = true
        let mac = controller()
        #expect(ok(await mac.setDone("r1", true)))
        #expect(ok(await mac.setDone("r1", false)))
        #expect(calendar.reminderList[0].completed == false)
        #expect(reminderWrites.count == 2 && reminderWrites.last?.data.reminders[0].completed == false)
        calendar.failSetDone = true
        let refused = await mac.setDone("r1", true)
        #expect(!ok(refused))
        if case .failure(let error) = refused { #expect(error.message == "Couldn't update the reminder") }
        mac.stop()
    }

    @Test func addReminderWritesItAndTheFile() async {
        calendar.accessByKind[.reminders] = .granted
        settings.remindersOn = true
        let mac = controller()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ok(await mac.addReminder(ReminderDraft(title: "Call Ana", due: due, dueHasTime: true), list: "work")))
        #expect(calendar.added.count == 1 && calendar.added[0].list == "work" && calendar.added[0].draft.title == "Call Ana")
        #expect(reminderWrites.last?.data.reminders.contains { $0.title == "Call Ana" } == true)
        // Empty, off, or refused by macOS: nothing written to Reminders.
        #expect(!ok(await mac.addReminder(ReminderDraft(title: "", due: nil, dueHasTime: false), list: nil)))
        calendar.failAdd = true
        let refused = await mac.addReminder(ReminderDraft(title: "x", due: nil, dueHasTime: false), list: nil)
        if case .failure(let error) = refused { #expect(error.message == "Couldn't add the reminder") }
        calendar.failAdd = false
        settings.remindersOn = false
        #expect(!ok(await mac.addReminder(ReminderDraft(title: "y", due: nil, dueHasTime: false), list: nil)))
        #expect(calendar.added.count == 1)
        mac.stop()
    }

    @Test func reminderListsPutTheDefaultFirst() {
        calendar.accessByKind[.reminders] = .granted
        settings.remindersOn = true
        calendar.lists = [ReminderList(id: "work", name: "Acme", color: "#F5A524"),
                          ReminderList(id: "home", name: "Reminders", color: "#3478F6")]
        calendar.defaultList = "home"
        let mac = controller()
        #expect(mac.reminderLists().map(\.id) == ["home", "work"])
        settings.remindersOn = false
        #expect(mac.reminderLists().isEmpty)
    }

    @Test func turningOffWritesNotSetUp() async {
        calendar.accessByKind[.reminders] = .granted
        settings.remindersOn = true
        let mac = controller()
        await mac.turnedOn(.reminders)
        settings.remindersOn = false
        mac.turnedOff(.reminders)
        #expect(plainWrites.last?.status == .notSetUp && plainWrites.last?.id == .reminders)
        mac.stop()
    }

    @Test func agendaMonthRespectsTheSwitch() {
        calendar.accessByKind[.agenda] = .granted
        calendar.eventList = [AgendaEvent(id: "e1", title: "Call", calendar: "cal", start: .now, end: .now.addingTimeInterval(60),
                                          allDay: false)]
        let mac = controller()
        #expect(mac.month(.now).events.isEmpty && mac.month(.now).calendars.isEmpty)
        settings.agendaOn = true
        #expect(mac.month(.now).events.map(\.id) == ["e1"])
    }

    @Test func turningRemindersOffStopsTheLateWrite() async {
        calendar.accessByKind[.reminders] = .granted
        calendar.reminderList = [ReminderItem(id: "r1", title: "Invoice", list: "Work", listColor: "#F5A524", due: nil,
                                              dueHasTime: false, completed: false)]
        settings.remindersOn = true
        let mac = controller()
        _ = await mac.setDone("r1", true)
        settings.remindersOn = false
        mac.turnedOff(.reminders)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(plainWrites.last?.status == .notSetUp)
        if case .plain = box.writes.last {} else { Issue.record("a reminders file was written after turning off") }
        mac.stop()
    }

    @Test func opensOnlyWhatWasClicked() {
        let mac = controller()
        mac.openMail("abc@example.com")
        mac.openEvent("CAL:EV/1")
        #expect(box.opened.map(\.absoluteString) == ["message://%3Cabc@example.com%3E",
                                                      "ical://ekevent/CAL:EV%2F1?method=show&options=more"])
        #expect(scripts.runs.isEmpty)
    }
}
