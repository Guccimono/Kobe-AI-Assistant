import AppKit
import SwiftUI
import KobeKit

extension View {
    /// In a message field: Return sends, Shift+Return (like ⌥Return) starts a new line at the caret.
    func shiftReturnAddsLine() -> some View {
        onKeyPress(.return, phases: .down) { press in
            let action = ReturnKey.action(shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option))
            guard action == .newline else { return .ignored }
            // What ⌥Return does natively: the field editor inserts the line where the caret is.
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
    }
}
