import Foundation

/// The line under each Mac connection in Settings › Connections.
public enum MacConnectionCopy {
    /// "Off", "On", "Waiting for your OK in System Settings", "Kobe can't read Calendar: …", "Open Mail to finish
    /// setup", or the last read's own problem. `access` for Mail and Notes is `granted` once a read worked.
    public static func status(_ kind: MacKind, on: Bool, access: MacAccess, running: Bool, problem: String?) -> String {
        guard on else { return "Off" }
        if access == .denied { return kind.deniedCopy }
        if let problem { return problem }
        if kind.bundleID != nil, access != .granted, !running { return kind.finishSetupCopy }
        if access == .notAsked { return "Waiting for your OK in System Settings" }
        return "On"
    }

    /// Who reads a connection: the Mac apps are always read here; the others by Kobe Agent or the app's shim.
    public static func runner(_ id: WidgetID, owner: SnapshotSource) -> String {
        if MacKind(id) != nil { return "on this Mac" }
        return owner == .agent ? "via Kobe Agent" : "via the app"
    }
}
