import SwiftUI

/// The grab bar under the island: drag to make it taller (up to about 90% of the screen), double-click to reset.
/// Measured in screen coordinates; the panel follows live, the height is saved on mouse-up. (Ported from the old Kobe.)
struct ResizeHandle: View {
    let height: Double
    let onLive: (Double) -> Void
    let onCommit: (Double) -> Void
    let onReset: () -> Void
    @State private var start: (height: Double, mouseY: CGFloat)?
    @State private var last: Double?
    @State private var hovering = false

    var body: some View {
        // The kit spec: 46 × 4, white 26 %; brighter while hovered or dragged so the grab is visible.
        Capsule()
            .fill(Color.white.opacity(hovering || start != nil ? 0.45 : 0.26))
            .frame(width: 46, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .contentShape(.rect)
            .onHover { over in
                hovering = over
                if over { NSCursor.resizeUpDown.push() } else if start == nil { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in
                        let mouseY = NSEvent.mouseLocation.y
                        if start == nil { start = (height, mouseY) }
                        guard let start else { return }
                        // Screen y grows upward: dragging down makes the island taller.
                        let proposed = start.height + Double(start.mouseY - mouseY)
                        last = proposed
                        onLive(proposed)
                    }
                    .onEnded { _ in
                        if let last { onCommit(last) }
                        start = nil
                        last = nil
                        if !hovering { NSCursor.pop() }
                    }
            )
            .onTapGesture(count: 2) { onReset() }
            .help("Drag to resize; double-click to reset")
            .accessibilityLabel("Resize handle")
    }
}

#Preview {
    ResizeHandle(height: 400, onLive: { _ in }, onCommit: { _ in }, onReset: {})
        .padding().background(.black)
}
