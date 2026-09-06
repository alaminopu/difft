import Foundation

/// Which links from untrusted text the app will hand to the system.
///
/// PR descriptions, review comments and agent output are all rendered as
/// markdown, and their links are attacker-controlled on a PR from a fork.
/// Opening one is `NSWorkspace` launching whatever is registered for that
/// scheme, so the set is an allowlist rather than a blocklist of the schemes
/// currently known to be dangerous.
public enum DifftURLPolicy {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public static func allowsOpening(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }
}
