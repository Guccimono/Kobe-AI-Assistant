import Foundation

/// One connection pill on Home.
public struct ConnectionItem: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable { case connected, problem, notSetUp }

    public let id: String
    public let name: String
    public let icon: PhosphorIcon
    public let tint: RGB
    public let status: Status
    public let detail: String
}

public enum Connections {
    /// Stripe, GitHub, Vercel, WhatsApp, always in that order.
    public static let ids = ["stripe", "github", "vercel", "whatsapp"]

    public static func name(_ id: String) -> String {
        switch id {
        case "stripe": "Stripe"
        case "github": "GitHub"
        case "vercel": "Vercel"
        default: "WhatsApp"
        }
    }

    public static func icon(_ id: String) -> PhosphorIcon {
        switch id {
        case "stripe": .stripeLogoFill
        case "github": .githubLogoFill
        case "vercel": .triangleFill
        default: .whatsappLogoFill
        }
    }

    /// Pill colours.
    public static func tint(_ id: String) -> RGB {
        switch id {
        case "stripe": RGB(0x0570DE)
        case "github": RGB(0xF4505E)
        case "vercel": RGB(0x7C5CFF)
        default: RGB(0x25D366)
        }
    }

    /// The four pills from each service's status and one-line detail; a missing status is "not set up".
    public static func items(status: [String: ConnectionItem.Status], detail: [String: String] = [:]) -> [ConnectionItem] {
        ids.map { id in
            ConnectionItem(id: id, name: name(id), icon: icon(id), tint: tint(id), status: status[id] ?? .notSetUp,
                           detail: detail[id] ?? "Integration")
        }
    }
}
