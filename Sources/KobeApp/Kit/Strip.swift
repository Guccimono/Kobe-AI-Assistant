import SwiftUI
import KobeKit

/// The connections as overlapping capsules in the tab bar (K W A R G S GH ▲ N). The page on screen stays raised;
/// hovering raises the one under the pointer, and hover or ⌘-hold shows its name, status and key underneath.
/// Geometry, keys, tints and copy come from `StripLayout`; this view only draws them.
struct Strip: View {
    let app: AppModel
    /// Index under the pointer, from the resting positions so the slide never moves the target under the mouse.
    @State private var hovered: Int?

    private let order = StripLayout.order

    var body: some View {
        let current = app.island.currentPage.flatMap { order.firstIndex(of: $0) }
        let raised = hovered ?? current
        let showsLabel = hovered != nil || app.island.commandHeld

        ZStack(alignment: .topLeading) {
            ForEach(Array(order.enumerated()), id: \.element) { index, id in
                StripCapsule(id: id, raised: index == raised) { app.openPage(id) }
                    .offset(x: StripLayout.slide + StripLayout.x(index: index, raised: raised))
                    .zIndex(zIndex(index, raised: raised))
            }
            // Badges ride above every capsule so the overlap never hides one.
            ForEach(Array(order.enumerated()), id: \.element) { index, id in
                if let kind = badge(id) {
                    Badge(kind: kind).scaleEffect(0.7)
                        .offset(x: StripLayout.slide + StripLayout.x(index: index, raised: raised) + StripLayout.size - 13, y: -5)
                        .zIndex(200)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: StripLayout.width, height: StripLayout.size, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let index = Int(((point.x - StripLayout.slide) / StripLayout.step).rounded(.down))
                hovered = min(max(index, 0), order.count - 1)
            case .ended:
                hovered = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if showsLabel, let raised {
                let id = order[raised]
                // Mail says how many are unread; the others say their status.
                let headline = id == .mail ? app.snapshots.envelopes[id]?.headline : nil
                Text(StripLayout.label(id, status: app.snapshots.envelopes[id]?.status, headline: headline))
                    .font(KFont.meta).foregroundStyle(K.text2).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black, in: Capsule())
                    .offset(x: StripLayout.slide + StripLayout.x(index: raised, raised: raised) - 2, y: StripLayout.size + 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: raised)
        .animation(.easeOut(duration: 0.12), value: showsLabel)
    }

    /// Raised on top; the rest stack towards it, so the overlap reads as a fan around the raised one.
    private func zIndex(_ index: Int, raised: Int?) -> Double {
        guard let raised else { return Double(index) }
        return index == raised ? 100 : Double(-abs(index - raised))
    }

    /// What happened while you were away (a service event) wins; otherwise the snapshot's own state when it asks.
    private func badge(_ id: WidgetID) -> Badge.Kind? {
        switch app.serviceBadges[id] {
        case .finished?: return .new
        case .attention?: return .needsYou
        case .error?: return .failed
        case nil: break
        }
        switch app.snapshots.envelopes[id]?.status {
        case .needsYou?: return .needsYou
        case .failed?: return .failed
        default: break
        }
        // Unread mail is news, not a need: the kit badge shows a kind, not a count.
        if id == .mail, (app.snapshots.mail?.data.unread ?? 0) > 0 { return .new }
        return nil
    }
}

/// One 28 pt capsule: the service tint, its Phosphor icon, a 2 pt black ring that separates it from its neighbours.
private struct StripCapsule: View {
    let id: WidgetID
    let raised: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(icon: StripLayout.icon(id), size: 14).foregroundStyle(K.window)
                .frame(width: StripLayout.size, height: StripLayout.size)
                .background(StripLayout.tint(id).color, in: Capsule())
                .overlay(Capsule().strokeBorder(.black, lineWidth: 2))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(raised ? StripLayout.raisedScale : 1)
        .accessibilityLabel(StripLayout.label(id, status: nil))
    }
}

/// A strip page that Kobe Agent will fill: the header in the service's colour and one plain line.
struct PlaceholderPage: View {
    let id: WidgetID

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            WidgetHeader(tint: StripLayout.tint(id).color, name: StripLayout.name(id), meta: "")
            Text("Coming with Kobe Agent").font(KFont.body).foregroundStyle(K.text2)
            Footer(keys: ["Cmd 1-9 pages", "Esc goes Home"])
        }
        .padding(Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface()
    }
}
