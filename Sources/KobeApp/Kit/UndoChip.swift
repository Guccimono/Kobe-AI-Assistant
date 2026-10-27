import SwiftUI
import KobeKit

/// "Completed · Undo" for a reversible action, instead of a confirmation dialog. Disappears after 5 s.
struct UndoChip: View {
    let text: String
    let onUndo: () -> Void
    @State private var visible = true

    var body: some View {
        if visible {
            HStack(spacing: 6) {
                Text(text).foregroundStyle(K.text1)
                Text("·").foregroundStyle(K.text3)
                Button("Undo") { visible = false; onUndo() }.buttonStyle(.plain).foregroundStyle(K.lime)
            }
            .font(KFont.meta.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(K.glassActive, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .task {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.easeOut(duration: 0.15)) { visible = false }
            }
            .transition(.opacity)
        }
    }
}

#Preview {
    UndoChip(text: "Completed", onUndo: {}).padding().background(.black)
}
