import AppKit
import Observation
import KobeKit

/// Where the notch is. On Macs without one, a drawn notch sits at the top centre of the main screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    /// Notch size in points (width × menu-bar-band height).
    var notchSize: CGSize
    /// Horizontal centre of the notch, in global screen coordinates.
    var midX: CGFloat

    /// nil when no screen is attached (lid closed, a display being unplugged, waking): callers keep the last geometry.
    static func current() -> NotchGeometry? {
        let screens = NSScreen.screens
        if let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                                 midX: screen.frame.minX + left.width + width / 2)
        }
        guard let screen = NSScreen.main ?? screens.first else { return nil }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: 185, height: menuBar > 10 ? menuBar : 24),
                             midX: screen.frame.midX)
    }

    /// The window frame for an island of `size`, anchored to the top of the screen at the notch centre.
    /// Before any screen is known: a 14" MacBook Pro's notch, replaced as soon as a screen reports in.
    static let placeholder = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                           notchSize: CGSize(width: 185, height: 37), midX: 756)

    func frame(for size: CGSize) -> CGRect {
        CGRect(x: (midX - size.width / 2).rounded(), y: screenFrame.maxY - size.height, width: size.width.rounded(), height: size.height)
    }
}

/// The island's base view. Drop and Chat are gone as tabs: the chat lives on Home's left pane, and a file
/// dropped on the island goes to the shared folder and into that field. Pages are overlays.
enum IslandTab: Equatable { case home }

/// Views that take over the open island's content area.
enum IslandOverlay: Equatable {
    case none
    case quickAsk
    case chatsList
    case claude
    /// A strip page: Home for `.now`; WhatsApp, Stripe, GitHub and Vercel on the kit; the others a placeholder
    /// until Kobe Agent writes them.
    case page(WidgetID)
}

@MainActor
@Observable
final class IslandModel {
    var geometry: NotchGeometry
    /// NotchMachine moves it; the controller animates every change (spring to grow, ease to fold).
    var phase: NotchPhase = .resting
    var tab: IslandTab = .home
    var overlay: IslandOverlay = .none
    var pinned = false
    var hovering = false
    /// ⌘ held for more than 0.3 s while open: the strip shows the raised capsule's label and key.
    var commandHeld = false
    /// Home's split: both panes, Now folded to a rail while writing, or the chat folded (`HomeLayout`).
    var homeMode: HomeMode = .split
    /// Height of the open island below the band, set by the resize handle.
    var contentHeight: CGFloat = PanelHeights.notchDefault
    var openWidth: CGFloat = PanelHeights.notchWidthDefault
    /// Measured heights, one per view, so a view opens at its own height instead of the last one's.
    private var fittedHeights: [String: CGFloat] = [:]

    /// The current view's measured height when it fits its content (everything but Home and the chats list).
    var fittedHeight: CGFloat {
        get { fittedHeights[viewKey] ?? 180 }
        set { fittedHeights[viewKey] = newValue }
    }

    private var viewKey: String { "\(tab)-\(overlay)" }

    /// Home (its chat) and the chats list scroll, so they keep the resizable height; every other view fits its
    /// content.
    var usesFittedHeight: Bool {
        switch overlay {
        case .chatsList, .none, .page(.now): false
        default: true
        }
    }

    static let barHeight: CGFloat = 44
    /// How far the notification band reaches on each side of the notch.
    static let bandWing: CGFloat = 190
    static let bottomPadding: CGFloat = 16

    init(geometry: NotchGeometry) { self.geometry = geometry }

    var expanded: Bool { phase == .expanded }

    /// The strip capsule that matches what is on screen: Home is K, a page is its own; the rest none.
    var currentPage: WidgetID? {
        switch overlay {
        case .page(let id): id
        case .none: .now
        default: nil
        }
    }

    static func rank(_ phase: NotchPhase) -> Int {
        switch phase {
        case .resting: 0
        case .compact: 1
        case .expanded: 2
        }
    }

    /// Quick ask is a narrower, shorter island.
    var isQuickAsk: Bool { overlay == .quickAsk }

    func bodySize(for phase: NotchPhase) -> CGSize {
        let notch = geometry.notchSize
        switch phase {
        case .resting: return notch
        case .compact: return CGSize(width: notch.width + 2 * Self.bandWing, height: notch.height)
        case .expanded:
            if isQuickAsk { return CGSize(width: max(600, notch.width), height: notch.height + 230) }
            if usesFittedHeight {
                return CGSize(width: max(openWidth, notch.width), height: max(notch.height, Self.barHeight) + fittedHeight + Self.bottomPadding)
            }
            return CGSize(width: max(openWidth, notch.width), height: notch.height + contentHeight)
        }
    }

    /// The concave flares at the top corners: none while hidden (it is the notch), 6 pt as the wings, 10 pt open.
    func flare(for phase: NotchPhase) -> CGFloat {
        switch phase {
        case .resting: 0
        case .compact: 6
        case .expanded: 10
        }
    }

    /// Corners: 14 pt closed and as the band, 22 pt open.
    func bottomRadius(for phase: NotchPhase) -> CGFloat {
        switch phase {
        case .resting, .compact: Radius.islandSmall
        case .expanded: Radius.islandOpen
        }
    }

    /// The window never changes size: it is as large as the island can ever get, clear and
    /// click-through except over the island, so the island animates inside it without a jump.
    var windowSize: CGSize {
        let widest = max(CGFloat(PanelHeights.notchWidthRange.upperBound), geometry.notchSize.width + 2 * Self.bandWing, 600)
        return CGSize(width: widest + 2 * Self.overshootMargin, height: geometry.screenFrame.height)
    }

    /// Room on each side for the opening spring's overshoot.
    static let overshootMargin: CGFloat = 40
}
