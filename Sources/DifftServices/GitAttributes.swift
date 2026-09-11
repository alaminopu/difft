import Foundation

/// What `.gitattributes` says about one file, as far as showing a diff for it
/// is concerned.
public struct GitFileAttributes: Equatable, Sendable {
    /// Marked `linguist-generated`. GitHub collapses these in its own diff
    /// view; the app labels them so a 4,000-line lockfile is recognisable as
    /// machine output rather than work to read.
    public var isGenerated: Bool
    /// The diff driver was turned off for this path (`-diff`). git then emits
    /// "Binary files a/x and b/x differ" for a perfectly readable text file,
    /// which is why these looked unviewable: there was no patch to parse.
    public var diffSuppressed: Bool

    public init(isGenerated: Bool = false, diffSuppressed: Bool = false) {
        self.isGenerated = isGenerated
        self.diffSuppressed = diffSuppressed
    }
}

public enum GitAttributes {
    /// Attributes to ask `git check-attr` for, in the order it reports them.
    public static let queried = ["diff", "linguist-generated"]

    /// Parses `git check-attr -z diff linguist-generated -- <paths>`.
    ///
    /// `-z` writes flat NUL-separated triples — path, attribute, value — with
    /// no line structure, which is the only form safe for paths containing
    /// spaces, quotes or newlines. Anything the parser does not recognise is
    /// skipped rather than throwing: a file whose attributes cannot be read
    /// should render as an ordinary file, not fail the open.
    public static func parse(_ output: String) -> [String: GitFileAttributes] {
        var result: [String: GitFileAttributes] = [:]
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 2 < fields.count {
            let path = fields[i], attribute = fields[i + 1], value = fields[i + 2]
            i += 3
            guard !path.isEmpty else { continue }
            var entry = result[path] ?? GitFileAttributes()
            switch (attribute, value) {
            case ("linguist-generated", "true"), ("linguist-generated", "set"):
                entry.isGenerated = true
            case ("diff", "unset"):
                entry.diffSuppressed = true
                // A path the repository has explicitly excluded from diffs is
                // generated output by intent, whether or not it also carries
                // the linguist marker.
                entry.isGenerated = true
            default:
                // "unspecified" and everything unrecognised say nothing. Only
                // files with something notable get an entry, so the caller can
                // skip the whole pass when the map comes back empty.
                continue
            }
            result[path] = entry
        }
        return result
    }
}
