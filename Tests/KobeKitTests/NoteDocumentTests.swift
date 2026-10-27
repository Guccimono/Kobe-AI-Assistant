import Foundation
import Testing
@testable import KobeKit

struct NoteDocumentTests {
    func editable(_ html: String) -> NoteDocument? {
        if case .success(let doc) = NoteDocument.parse(html: html, attachments: 0, locked: false) { return doc }
        return nil
    }

    @Test func headingTitleAndLines() {
        let html = "<div><h1>Menu ideas</h1></div>\n<div>Tacos al pastor</div>\n<div><br></div>\n<div>Flan &amp; café</div>"
        let doc = editable(html)
        #expect(doc?.text == "Menu ideas\nTacos al pastor\n\nFlan & café")
        #expect(doc?.titleStyle == .heading)
        #expect(doc?.html(from: doc!.text) == "<div><h1>Menu ideas</h1></div><div>Tacos al pastor</div><div><br></div><div>Flan &amp; café</div>")
    }

    @Test func boldTitleAndAList() {
        let doc = editable("<div><b>Trip</b></div><ul><li>Book the flight</li><li>Pack &lt;the&gt; charger</li></ul><div><br></div>")
        #expect(doc?.titleStyle == .bold)
        #expect(doc?.text == "Trip\n- Book the flight\n- Pack <the> charger\n")
        let edited = "Trip\n- Book the flight\n- Pack the charger\n- Passport\nDone"
        #expect(doc?.html(from: edited)
                == "<div><b>Trip</b></div><ul><li>Book the flight</li><li>Pack the charger</li><li>Passport</li></ul><div>Done</div>")
    }

    @Test func savingAnUneditedNoteChangesNothing() {
        // An empty last bullet, as Notes writes it, and a blank line after a list.
        for html in ["<div><h1>Today</h1></div><ul><li>One</li><li><br></li></ul>",
                     "<div><b>Trip</b></div><ul><li>Book</li></ul><div><br></div>"] {
            let doc = editable(html)!
            #expect(doc.html(from: doc.text) == html)
        }
        #expect(editable("<div><h1>Today</h1></div><ul><li>One</li><li><br></li></ul>")?.text == "Today\n- One\n- ")
        // A break that ends a block draws nothing in Notes: no empty line, none added on save.
        let titled = editable("<div><b>Trip</b><br></div>\n<div>Book</div>")
        #expect(titled?.text == "Trip\nBook")
        #expect(titled?.html(from: titled!.text) == "<div><b>Trip</b></div><div>Book</div>")
        #expect(editable("<div>A</div><div><br></div><div>B</div>")?.text == "A\n\nB")
    }

    @Test func lineBreaksInsideADiv() {
        #expect(editable("<div>One<br>Two</div>")?.text == "One\nTwo")
        #expect(editable("Plain first line<div>second</div>")?.text == "Plain first line\nsecond")
    }

    @Test func escapesWhatIsTyped() {
        let doc = editable("<div>T</div>")!
        #expect(doc.html(from: "T\n<b>x</b> & \"y\"") == "<div>T</div><div>&lt;b&gt;x&lt;/b&gt; &amp; \"y\"</div>")
    }

    @Test func richNotesStayReadOnly() {
        func reason(_ html: String, attachments: Int = 0, locked: Bool = false) -> NoteDocument.ReadOnly? {
            if case .failure(let r) = NoteDocument.parse(html: html, attachments: attachments, locked: locked) { return r }
            return nil
        }
        #expect(reason("<div>a</div>", locked: true) == .locked)
        #expect(reason("<div>a</div>", attachments: 1) == .attachments)
        #expect(reason("<div>T</div><div>some <b>bold</b> word</div>") == .formatting)
        #expect(reason("<div>T</div><div><a href=\"https://x\">link</a></div>") == .formatting)
        #expect(reason("<div>T</div><table><tr><td>x</td></tr></table>") == .formatting)
        #expect(reason("<div style=\"color:red\">T</div>") == .formatting)
        #expect(reason("<div>T</div><ul class=\"checklist\"><li>x</li></ul>") == .formatting)
    }
}
