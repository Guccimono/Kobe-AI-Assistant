import SwiftUI
import KobeKit

/// A Settings card: one step lighter than the window, radius 26, generous padding, optional eyebrow + title.
struct Card<Content: View>: View {
    var eyebrow: String?
    var title: String?
    var trailing: AnyView?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if eyebrow != nil || title != nil {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let eyebrow { Eyebrow(eyebrow) }
                        if let title { Text(title).font(.system(size: 21, weight: .semibold)).tracking(-0.2).foregroundStyle(K.text1) }
                    }
                    Spacer()
                    if let trailing { trailing }
                }
                .padding(.bottom, 18)
            }
            content
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(K.panel, radius: 26)
    }
}

/// A big stat number with its label.
struct BigNumber: View {
    let value: String
    let label: String
    var chip: StatusChip?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.system(size: 60, weight: .bold)).tracking(-2).foregroundStyle(K.text1)
            HStack(spacing: 8) {
                Text(label).font(KFont.body).foregroundStyle(K.text2)
                if let chip { chip }
            }
        }
    }
}

/// The secondary action at the end of a card ("All chats"): a full-width kit glass button.
struct CardActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(GlassButtonStyle())
            .padding(.top, Spacing.md)
    }
}

/// One list row with an icon, two lines and a trailing view; hairline above. Kit type (row, secondary).
struct ListRow<Trailing: View>: View {
    let icon: PhosphorIcon
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(K.hairline).frame(height: 1)
            HStack(spacing: Spacing.md) {
                Icon(icon: icon, size: 18).foregroundStyle(K.text2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(KFont.row).foregroundStyle(K.text1).lineLimit(1)
                    if let subtitle { Text(subtitle).font(KFont.secondary).foregroundStyle(K.text3).lineLimit(1) }
                }
                Spacer()
                trailing
            }
            .padding(.vertical, Spacing.md)
        }
    }
}

/// The page title with the page's main action on the right.
struct PageHeader<Actions: View>: View {
    let title: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 38, weight: .bold)).tracking(-0.8).foregroundStyle(K.text1)
            Spacer()
            actions
        }
    }
}

/// A labelled setting row inside a card. Kit type (row, secondary).
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(KFont.row).foregroundStyle(K.text1)
                if let detail { Text(detail).font(KFont.secondary).foregroundStyle(K.text3).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            control
        }
        .padding(.vertical, 10)
    }
}
