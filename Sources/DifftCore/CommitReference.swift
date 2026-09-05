import Foundation

/// Finds commit SHAs written bare in prose, the way review comments mention
/// them: "Fixed in d59f520cc and b32db62bf."
public enum CommitReference {
    /// Git's own abbreviation floor is 7; a full SHA is 40.
    static let minLength = 7
    static let maxLength = 40

    /// Character ranges of every SHA-looking token in `text`.
    ///
    /// A token must be hex and contain at least one letter, which is what
    /// keeps a plain number out: "1234567" is valid hex and would otherwise
    /// be linked as a commit, and review comments are full of line numbers
    /// and counts.
    public static func ranges(in text: String) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var start: Int?
        var hasLetter = false
        var index = 0

        func flush(end: Int) {
            defer { start = nil; hasLetter = false }
            guard let s = start, hasLetter else { return }
            let length = end - s
            guard length >= minLength, length <= maxLength else { return }
            found.append(s..<end)
        }

        for ch in text {
            if ch.isHexDigitLower {
                if start == nil { start = index }
                if ch.isLetter { hasLetter = true }
            } else if isWordCharacter(ch) {
                // Part of a longer identifier such as `abc123def_name`, so the
                // hex run is not a standalone reference.
                start = nil
                hasLetter = false
            } else {
                flush(end: index)
            }
            index += 1
        }
        flush(end: index)
        return found
    }

    private static func isWordCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    /// Scheme for a SHA link, so clicking one opens the commit in the diff
    /// viewer instead of handing the reader off to a browser.
    public static let scheme = "difft-commit"

    public static func url(sha: String) -> URL? {
        URL(string: "\(scheme)://commit/\(sha)")
    }

    /// The SHA a link carries, or nil if this is an ordinary link that should
    /// be left to the system.
    public static func sha(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let sha = url.lastPathComponent
        guard !sha.isEmpty, sha != "/" else { return nil }
        return sha
    }
}

private extension Character {
    /// Git prints SHAs in lowercase; accepting uppercase would drag in
    /// constants and acronyms.
    var isHexDigitLower: Bool {
        isNumber || ("a"..."f").contains(self)
    }
}
