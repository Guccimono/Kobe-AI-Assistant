import SwiftUI
import KobeKit

/// Three tones plus neutral. `green`, `amber` and `red` are the names Settings already uses.
enum ChipTone: Equatable {
    case ok, needsYou, failed, neutral
    static let green = ChipTone.ok
    static let amber = ChipTone.needsYou
    static let red = ChipTone.failed

    /// A snapshot's status as a tone; no snapshot (or `not_set_up`) is neutral, never guessed.
    init(_ status: SnapshotStatus?) {
        self = switch status {
        case .ok: .ok
        case .needsYou: .needsYou
        case .failed: .failed
        case .notSetUp, nil: .neutral
        }
    }

    var color: Color {
        switch self {
        case .ok: K.green
        case .needsYou: K.amber
        case .failed: K.red
        case .neutral: K.text2
        }
    }
}

/// A small tinted status chip: text, never an icon alone. The kit spec: 11 pt semibold in the tone colour on the
/// same colour at 16 %, no border (a border made Settings' chips read as buttons), chip radius.
struct StatusChip: View {
    let text: String
    let tone: ChipTone

    var body: some View {
        let color = tone.color
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}

#Preview {
    HStack {
        StatusChip(text: "All good", tone: .ok)
        StatusChip(text: "Needs you", tone: .needsYou)
        StatusChip(text: "Failed", tone: .failed)
        StatusChip(text: "Idle", tone: .neutral)
    }
    .padding().background(.black)
}
