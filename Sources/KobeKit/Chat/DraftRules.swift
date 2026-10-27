import Foundation

/// What of the composer's text may be kept between launches. Keys and very long pastes never are.
public enum DraftRules {
    public static let maxLength = 4000
    public static let keyPrefixes = ["sk-", "sk_", "rk_", "whsec_", "ghp_", "gho_", "ghs_", "ghu_", "github_pat_", "xox"]

    public static func persistable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxLength { return false }
        let lower = trimmed.lowercased()
        return !keyPrefixes.contains { lower.hasPrefix($0) }
    }
}
