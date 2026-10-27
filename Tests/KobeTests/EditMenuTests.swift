import AppKit
import Testing
@testable import KobeApp

@MainActor
struct EditMenuTests {
    @Test func editMenuRoutesTheStandardShortcuts() {
        let edit = EditMenu.editMenu()
        let wanted: [(String, String, NSEvent.ModifierFlags)] = [
            ("Undo", "z", .command), ("Redo", "z", [.command, .shift]), ("Cut", "x", .command),
            ("Copy", "c", .command), ("Paste", "v", .command), ("Select All", "a", .command),
        ]
        for (title, key, flags) in wanted {
            let item = edit.item(withTitle: title)
            #expect(item?.keyEquivalent == key, "\(title)")
            #expect(item?.keyEquivalentModifierMask == flags, "\(title)")
            #expect(item?.action != nil, "\(title)")
        }
        // The main menu carries it as its second menu, the place AppKit looks for Edit.
        #expect(EditMenu.mainMenu().items.count == 2)
        #expect(EditMenu.mainMenu().items[1].submenu?.title == "Edit")
    }
}
