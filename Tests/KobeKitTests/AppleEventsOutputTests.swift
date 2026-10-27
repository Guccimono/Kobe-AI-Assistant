import Foundation
import Testing
@testable import KobeKit

struct AppleEventsOutputTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let US = "\u{1F}", RS = "\u{1E}"

    func record(_ fields: [String]) -> String { fields.joined(separator: US) + RS }

    @Test func parsesMailRecords() {
        let text = record(["#unread", "212"]) + record(["CAF=abc@mail.gmail.com", "Ana <ana@example.com>", "Menu", "-3600", "false", "Google", "Hi there"])
            + record(["<receipt@stripe.com>", "Stripe", "Receipt", "-60", "true", "iCloud", "Thanks"])
        let read = AppleEventsOutput.mailRead(text, now: now)
        #expect(read.unread == 212)
        let messages = read.messages
        #expect(messages.count == 2)
        #expect(messages[0] == MailMessage(id: "CAF=abc@mail.gmail.com", sender: "Ana <ana@example.com>", subject: "Menu",
                                           preview: "Hi there", at: now.addingTimeInterval(-3600), unread: true,
                                           account: "Google"))
        #expect(messages[1].id == "receipt@stripe.com" && !messages[1].unread)
    }

    @Test func dropsMalformedRecords() {
        let good = record(["a", "S", "s", "-1", "false", "G", "p"])
        let short = record(["b", "S", "s", "-1", "false", "G"])
        #expect(AppleEventsOutput.mailRead(good + short + good, now: now).messages.count == 2)
        #expect(AppleEventsOutput.mailRead("", now: now).messages.isEmpty)
        #expect(AppleEventsOutput.records("", fields: 7).isEmpty)
        let huge = record(["c", "S", "s", "-1", "false", "G", String(repeating: "z", count: 20_000)])
        #expect(AppleEventsOutput.mailRead(huge, now: now).messages.count == 1)
    }

    @Test func separatorsInsideFieldsCannotSplit() {
        let text = record(["a", "S", "s", "-1", "false", "G", "line one\nline two\r\nthree"])
        let messages = AppleEventsOutput.mailRead(text, now: now).messages
        #expect(messages.count == 1 && messages[0].preview.contains("line two"))
        // The scripts replace the separators inside every field before joining.
        #expect(MacScripts.mail.contains("character id 30") && MacScripts.mail.contains("character id 31"))
        #expect(MacScripts.mail.contains("on clean("))
    }

    @Test func localeFreeDates() {
        let text = record(["a", "S", "s", "24/10/2026", "false", "G", "p"]) + record(["b", "S", "s", "-5", "false", "G", "p"])
        #expect(AppleEventsOutput.mailRead(text, now: now).messages.map(\.id) == ["b"])
    }

    @Test func parsesNotes() {
        let index = record(["x-coredata://A/ICNote/p1", "Menu ideas", "Notes", "-7200"])
            + record(["x-coredata://A/ICNote/p2", "Trip", "Notes", "nope"])
            + record(["x-coredata://A/ICNote/p1", "Menu ideas", "Notes", "-7200"])
        let parsed = AppleEventsOutput.notesIndex(index, now: now)
        #expect(parsed.count == 1)
        #expect(parsed[0].id == "x-coredata://A/ICNote/p1" && parsed[0].title == "Menu ideas" && parsed[0].folder == "Notes")
        #expect(parsed[0].modified == now.addingTimeInterval(-7200))
        let bodies = AppleEventsOutput.notesBodies(record(["x-coredata://A/ICNote/p1", "Tacos\nFlan"]))
        #expect(bodies["x-coredata://A/ICNote/p1"] == "Tacos\nFlan")
    }

    @Test func readScriptsNeverLaunchTheApp() {
        // `application id … is running` never launches; the guard comes before any `tell`.
        for (script, bundle) in [(MacScripts.mail, "com.apple.mail"), (MacScripts.notesIndex, "com.apple.Notes"),
                                 (MacScripts.notesBody(ids: ["a"]), "com.apple.Notes")] {
            let guardLine = "if not (application id \"\(bundle)\" is running) then error number -600"
            let guardAt = script.range(of: guardLine)
            let tellAt = script.range(of: "tell application")
            #expect(guardAt != nil && tellAt != nil)
            if let guardAt, let tellAt { #expect(guardAt.lowerBound < tellAt.lowerBound) }
        }
    }

    @Test func oneBadRecordIsSkipped() {
        // Each record in its own try; a quit app or a refusal still ends the read.
        for script in [MacScripts.mail, MacScripts.notesIndex, MacScripts.notesBody(ids: ["a"])] {
            #expect(script.contains("on error number errNum"))
            #expect(script.contains("if errNum is -600 or errNum is -1743 or errNum is -1744 then error number errNum"))
        }
    }

    @Test func mailCountsTheWholeInboxAndPicksByDate() {
        #expect(MacScripts.mail.contains("unread count of inbox"))
        #expect(MacScripts.mail.contains("whose date received >"))
        #expect(AppleEventsOutput.mailRead(record(["#unread", "x"]), now: now).unread == nil)
    }

    @Test func notesSkipRecentlyDeleted() {
        for name in ["Recently Deleted", "Eliminados recientemente", "Suppressions récentes", "Zuletzt gelöscht"] {
            #expect(MacScripts.notesIndex.contains(name))
        }
    }

    @Test func scriptVariablesNeverClash() {
        // AppleScript names ignore case (`rs` is `RS`, the record separator), and Mail's or Notes' own words
        // (`dates`, `body`) can't hold a value inside a `tell`.
        let reserved: Set<String> = ["date", "dates", "body", "content", "name", "names", "id", "ids", "text",
                                     "note", "notes", "folder", "folders", "message", "messages", "account"]
        let setName = /set ([A-Za-z_][A-Za-z0-9_]*) to/
        for script in [MacScripts.mail, MacScripts.notesIndex, MacScripts.notesBody(ids: ["a"]), MacScripts.noteRead(id: "a"),
                       MacScripts.noteWrite(id: "a", html: "<div>x</div>", modifiedEpoch: 1)] {
            var spelled: [String: String] = [:]
            for match in script.matches(of: setName) {
                let name = String(match.output.1)
                #expect(!reserved.contains(name.lowercased()), "\(name) is a reserved word")
                if let other = spelled[name.lowercased()] { #expect(other == name, "\(name) clashes with \(other)") }
                spelled[name.lowercased()] = name
            }
        }
    }

    @Test func noteReadAndWrite() {
        let read = MacScripts.noteRead(id: #"x-coredata://A/"p1""#)
        #expect(read.contains(#"note id "x-coredata://A/\"p1\"""#) && read.contains("password protected"))
        #expect(read.hasPrefix(MacScripts.helpers + MacScripts.running("com.apple.Notes")))
        let write = MacScripts.noteWrite(id: "n1", html: #"<div>"Hi" \ there</div>"#, modifiedEpoch: 1_800_000_000)
        #expect(write.contains(#"set body of note id "n1" to "<div>\"Hi\" \\ there</div>""#))
        #expect(write.contains("1800000000") && write.contains("#changed") && write.contains("#locked"))
        // The check comes before the write.
        if let check = write.range(of: "#changed"), let set = write.range(of: "set body of") {
            #expect(check.lowerBound < set.lowerBound)
        }
        #expect(write.hasPrefix(MacScripts.running("com.apple.Notes")))

        let fields = record(["-120", "false", "0", "<div>Hi</div>", "Hi\nthere"])
        let parsed = AppleEventsOutput.noteRead(fields, now: now)
        #expect(parsed?.modified == now.addingTimeInterval(-120) && parsed?.locked == false && parsed?.attachments == 0)
        #expect(parsed?.html == "<div>Hi</div>" && parsed?.plain == "Hi\nthere")
        #expect(AppleEventsOutput.noteRead("", now: now) == nil)
        #expect(AppleEventsOutput.noteWrite(record(["#saved", "-1"]), now: now) == .saved(now.addingTimeInterval(-1)))
        #expect(AppleEventsOutput.noteWrite(record(["#changed"]), now: now) == .changed)
        #expect(AppleEventsOutput.noteWrite(record(["#locked"]), now: now) == .locked)
        #expect(AppleEventsOutput.noteWrite("junk", now: now) == nil)
    }

    @Test func errorsMapToProblems() {
        #expect(AppleEventsError.from(code: -600) == .notRunning)
        #expect(AppleEventsError.from(code: -1743) == .denied)
        #expect(AppleEventsError.from(code: -1744) == .denied)
        #expect(AppleEventsError.from(code: -1708) == .other("Apple Events error -1708"))
    }

    @Test func osascriptErrorsMapToProblems() {
        #expect(AppleEventsError.from(stderr: "33:40: execution error: Not authorized to send Apple events to Mail. (-1743)\n") == .denied)
        #expect(AppleEventsError.from(stderr: "execution error: Mail got an error: Application isn't running. (-600)") == .notRunning)
        #expect(AppleEventsError.from(stderr: "weird") == .other("Couldn't read: weird"))
        #expect(AppleEventsError.from(stderr: "") == .other("Couldn't read"))
    }

    @Test func notesShowEscapes() {
        let script = MacScripts.notesShow(id: #"x-coredata://A/"evil"\p1"#)
        #expect(script.contains(#"note id "x-coredata://A/\"evil\"\\p1""#))
        #expect(script.contains("activate"))
        let body = MacScripts.notesBody(ids: [#"a"b"#])
        #expect(body.contains(#""a\"b""#))
    }
}
