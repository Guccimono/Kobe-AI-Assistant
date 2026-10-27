import Foundation

/// Every identifier the app owns, in one place. Info.plist, Package.swift and the scripts repeat these as literals
/// (they cannot import Swift); BrandTests keeps the Swift side honest.
public enum Brand {
    public static let bundleID = "com.kobe-assistant.app"
    public static let hookBundleID = "com.kobe-assistant.app.hook"
    public static let servicesKeychain = "com.kobe-assistant.app.services"
    public static let engineKeychain = "com.kobe-assistant.app.engine"
    /// Folder under Application Support (and Logs) that holds the app's runtime data.
    public static let dataFolderName = "Kobe"
    public static let appName = "Kobe"
}
