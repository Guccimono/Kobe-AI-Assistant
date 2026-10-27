import SwiftUI
import KobeKit

/// An 18 pt status badge for the edge of a strip pill. The 2 pt black ring separates it from what it overlaps.
struct Badge: View {
    enum Kind { case new, needsYou, failed }
    let kind: Kind

    var body: some View {
        Circle().fill(color)
            .overlay { Icon(icon: icon, size: 9).foregroundStyle(K.window) }
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.black, lineWidth: 2))
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch kind {
        case .new: K.green
        case .needsYou: K.amber
        case .failed: K.red
        }
    }

    private var icon: PhosphorIcon {
        switch kind {
        case .new: .check
        case .needsYou: .exclamationMark
        case .failed: .x
        }
    }

    private var label: String {
        switch kind {
        case .new: "New"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        }
    }
}

#Preview {
    HStack { Badge(kind: .new); Badge(kind: .needsYou); Badge(kind: .failed) }
        .padding().background(.black)
}
