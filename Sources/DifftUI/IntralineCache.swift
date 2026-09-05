import Foundation
import DifftCore

/// Memoises word-level diffs.
///
/// `IntralineDiff.changedRanges` was being called from inside `body`, on the
/// main actor, for every visible changed row and on every body evaluation —
/// including each frame of a panel-width animation. Its LCS allocates an
/// `(n+1)×(m+1)` table, so a single long minified line could stall the UI.
/// This caches results and refuses inputs large enough to be a problem.
final class IntralineCache: @unchecked Sendable {
    static let shared = IntralineCache()

    /// Above this, the quadratic table costs more than the emphasis is worth.
    /// Lines this long are minified or generated — the word-level detail is
    /// not readable anyway, so they simply render without emphasis.
    static let maxLength = 2_000

    private let cache = NSCache<NSString, Box>()
    private init() { cache.countLimit = 4_000 }

    func ranges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        guard old.count <= Self.maxLength, new.count <= Self.maxLength else { return ([], []) }
        let key = "\(old)\u{1}\(new)" as NSString
        if let hit = cache.object(forKey: key) { return (hit.old, hit.new) }
        let computed = IntralineDiff.changedRanges(old: old, new: new)
        cache.setObject(Box(computed.old, computed.new), forKey: key)
        return computed
    }

    private final class Box {
        let old: [Range<Int>], new: [Range<Int>]
        init(_ old: [Range<Int>], _ new: [Range<Int>]) { self.old = old; self.new = new }
    }
}
