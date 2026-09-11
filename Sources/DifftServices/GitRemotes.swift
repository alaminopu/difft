import Foundation

/// Pure parsing of `git remote -v`, kept apart from the process call so the
/// matching rules can be tested without a git checkout.
public enum GitRemotes {
    /// Name of the remote whose URL points at `nameWithOwner` ("owner/repo").
    ///
    /// Handles both URL forms git writes:
    ///   `git@github.com:owner/repo.git`
    ///   `https://github.com/owner/repo.git`
    /// and tolerates a missing `.git`. GitHub treats owner and repo names
    /// case-insensitively, so the comparison does too.
    public static func matching(nameWithOwner: String, in remoteOutput: String) -> String? {
        let wanted = nameWithOwner.lowercased()
        guard !wanted.isEmpty else { return nil }
        // `origin` first when several remotes point at the same repository:
        // it is the conventional one, and picking another would surprise.
        var found: [String] = []
        for line in remoteOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            let name = String(fields[0])
            guard slug(from: String(fields[1])) == wanted else { continue }
            if !found.contains(name) { found.append(name) }
        }
        return found.contains("origin") ? "origin" : found.first
    }

    /// "owner/repo", lowercased, from a remote URL. nil when the URL is not a
    /// shape we recognise.
    static func slug(from url: String) -> String? {
        var s = url
        if let hash = s.firstIndex(of: "#") { s = String(s[s.startIndex..<hash]) }
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        // scp-like: git@host:owner/repo
        if let colon = s.lastIndex(of: ":"), !s.contains("://") {
            s = String(s[s.index(after: colon)...])
        } else if let range = s.range(of: "://") {
            // scheme://[user@]host/owner/repo
            let rest = String(s[range.upperBound...])
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            s = String(rest[rest.index(after: slash)...])
        }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2])/\(parts[parts.count - 1])".lowercased()
    }
}
