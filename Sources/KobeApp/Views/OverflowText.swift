import SwiftUI
import KobeKit

/// Text shown whole, never cut: a command, a file edit, a request. Past `maxHeight` it scrolls, with "+N more
/// lines" while the end is out of view. It reports itself as a card on screen (`AllowLockReporter`): locked until
/// measured, while it overflows and the end hasn't been seen, and gone (locked) once off screen, so a hotkey can't
/// allow what wasn't read; the Allow button itself always works.
struct OverflowText: View {
    let text: String
    let font: Font
    let color: Color
    /// Height of one line in `font`, for the "+N more lines" count.
    var lineHeight: CGFloat = 17
    var maxHeight: CGFloat = 220
    var onLockChange: (UUID, Bool?) -> Void = { _, _ in }

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var sawEnd = false

    private var overflows: Bool { viewportHeight > 0 && contentHeight > viewportHeight + 1 }
    private var hiddenBelow: CGFloat { max(0, contentHeight - viewportHeight - scrollOffset) }
    private var hiddenLines: Int { Int((hiddenBelow / lineHeight).rounded(.up)) }
    /// Not measured yet counts as locked: nothing is allowed before its size is known.
    private var locked: Bool { viewportHeight <= 0 || contentHeight <= 0 || (overflows && !sawEnd) }

    var body: some View {
        ScrollView {
            Text(text).font(font).foregroundStyle(color).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, overflows ? 22 : 0)   // room for the marker over the last line
                .background(GeometryReader { proxy in Color.clear.preference(key: MeasuredHeightKey.self, value: proxy.size.height) })
        }
        .scrollIndicators(overflows ? .automatic : .never)
        .onPreferenceChange(MeasuredHeightKey.self) { contentHeight = $0 }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, offset in
            scrollOffset = max(0, offset)
            if viewportHeight > 0, contentHeight - viewportHeight - scrollOffset <= 4 { sawEnd = true }
        }
        .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
        .background(GeometryReader { proxy in Color.clear.preference(key: ViewportHeightKey.self, value: proxy.size.height) })
        .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
        .overlay(alignment: .bottomTrailing) {
            if overflows, hiddenLines > 0 {
                Text("+\(hiddenLines) more \(hiddenLines == 1 ? "line" : "lines")")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(K.text2)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(K.panel3, in: Capsule())
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onChange(of: text) { sawEnd = false }
        .modifier(AllowLockReporter(locked: locked, report: onLockChange))
    }
}

/// One card on screen, for `AllowLock`: its state on appear and on every change, and nil (gone, so locked) when it
/// leaves the screen. Each view instance has its own id, so a card moving between views never inherits a "seen".
struct AllowLockReporter: ViewModifier {
    let locked: Bool
    let report: (UUID, Bool?) -> Void
    @State private var card = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { report(card, locked) }
            .onChange(of: locked) { report(card, $1) }
            .onDisappear { report(card, nil) }
    }
}

private struct ScrollMetrics: Equatable {
    var viewport: CGFloat
    var offset: CGFloat
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct MeasuredHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
