import Foundation

/// The four Mac apps Kobe App reads for itself (Kobe Agent can't: they belong to the person's account, not the engine's).
public enum MacKind: String, CaseIterable, Sendable {
    case mail, agenda, reminders, notes

    public var id: WidgetID {
        switch self {
        case .mail: .mail
        case .agenda: .agenda
        case .reminders: .reminders
        case .notes: .notes
        }
    }

    public init?(_ id: WidgetID) {
        switch id {
        case .mail: self = .mail
        case .agenda: self = .agenda
        case .reminders: self = .reminders
        case .notes: self = .notes
        default: return nil
        }
    }

    /// The app's name, as macOS shows it in Privacy & Security.
    public var app: String {
        switch self {
        case .mail: "Mail"
        case .agenda: "Calendar"
        case .reminders: "Reminders"
        case .notes: "Notes"
        }
    }

    /// Mail and Notes are read through Apple Events, only while they run; Calendar and Reminders through EventKit.
    public var bundleID: String? {
        switch self {
        case .mail: "com.apple.mail"
        case .notes: "com.apple.Notes"
        case .agenda, .reminders: nil
        }
    }

    /// "Kobe can't read Calendar: allow it in System Settings › Privacy & Security".
    public var deniedCopy: String { "Kobe can't read \(app): allow it in System Settings › Privacy & Security" }
    /// Mail and Notes before their first read: Kobe never opens them itself.
    public var finishSetupCopy: String { "Open \(app) to finish setup" }
}

/// Where macOS stands on Kobe reading an app.
public enum MacAccess: Equatable, Sendable {
    case notAsked, granted, denied
}
