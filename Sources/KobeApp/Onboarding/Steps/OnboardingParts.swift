import SwiftUI
import KobeKit

/// The pieces every step shares, kept to the kit's tokens.
struct StepHeading: View {
    let title: String
    let lead: Text

    init(title: String, lead: String) { self.title = title; self.lead = Text(lead) }
    init(title: String, lead: Text) { self.title = title; self.lead = lead }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The one display size on these screens; the kit has no larger style.
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.2).foregroundStyle(K.text1)
            lead.font(KFont.body).foregroundStyle(K.text2)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560, alignment: .leading)
        }
        .padding(.top, 6).padding(.bottom, 16)
    }
}

/// A glass card: title, one muted line, and anything trailing.
struct InfoCard<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    init(title: String, detail: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.detail = detail; self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(KFont.row).foregroundStyle(K.text1)
                Text(detail).font(KFont.secondary).foregroundStyle(K.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(K.panel, radius: Radius.islandSmall)
    }
}

struct MutedLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(KFont.secondary).foregroundStyle(K.text3).fixedSize(horizontal: false, vertical: true)
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(KFont.secondary).foregroundStyle(K.text3) }
}

/// A one-line text or secure field on glass.
struct OnboardingField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain).font(KFont.body).foregroundStyle(K.text1)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(K.glass, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }
}

/// A pill the person picks (voice, tone, Keep it).
struct ChoiceChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(KFont.body).foregroundStyle(on ? K.text1 : K.text2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? K.lime.opacity(0.14) : K.glass, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? K.lime.opacity(0.6) : Color.clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The status row: a dot, a bold line, a muted line, and a button or two.
struct StatusRow<Trailing: View>: View {
    let color: Color
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Dot(color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(KFont.row).foregroundStyle(K.text1)
                Text(detail).font(KFont.secondary).foregroundStyle(K.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(K.panel, radius: Radius.islandSmall)
    }
}

extension KeyTone {
    var chipTone: ChipTone {
        switch self {
        case .ok: .ok
        case .needsYou: .needsYou
        case .failed: .failed
        case .neutral: .neutral
        }
    }
}

let twoColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
