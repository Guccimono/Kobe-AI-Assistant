import AppKit
import SwiftUI
import KobeKit

extension PageKey {
    /// From the island's keyDown monitor (`PageKey`, `PageKeyboard` and their rules live in KobeKit).
    init?(code: UInt16, flags: NSEvent.ModifierFlags) {
        self.init(code: code, command: flags == .command, plain: flags.isEmpty)
    }
}

/// Claims the keyboard while the view is on screen and hands it the keys it asked for.
private struct PageKeysModifier: ViewModifier {
    let keyboard: PageKeyboard
    let keys: Set<PageKey>
    let onKey: (PageKey) -> Void
    @State private var token = UUID().uuidString

    func body(content: Content) -> some View {
        content
            .onAppear { keyboard.claim(token, keys: keys) }
            .onDisappear { keyboard.release(token) }
            // A conversation opening or a search starting changes what Esc means.
            .onChange(of: keys) { _, keys in keyboard.claim(token, keys: keys) }
            .onChange(of: keyboard.event) { _, event in
                guard let event, event.owner == token else { return }
                onKey(event.key)
            }
    }
}

extension View {
    func pageKeys(_ keyboard: PageKeyboard, _ keys: Set<PageKey>, onKey: @escaping (PageKey) -> Void) -> some View {
        modifier(PageKeysModifier(keyboard: keyboard, keys: keys, onKey: onKey))
    }
}
