/// A run of unchanged rows hidden behind a "N unchanged lines" band.
public struct CollapsedRegion: Equatable, Sendable, Identifiable {
    public let id: Int
    /// Indices into the row array this band stands in for.
    public let range: ClosedRange<Int>
    public init(id: Int, range: ClosedRange<Int>) { self.id = id; self.range = range }
    public var count: Int { range.count }
}

/// Decides which unchanged rows to fold away.
///
/// Difft asks git for unlimited context so the whole file is available to read
/// — but on a typical commit that means around 95% of the rows on screen are
/// untouched, and the changes are needles in them. Folding the long unchanged
/// runs keeps the file whole (every line is one click away) while making the
/// changes scannable, which is what GitHub's diff and VS Code's
/// `hideUnchangedRegions` both do.
public enum CollapsedRegions {
    /// Unchanged rows kept either side of a change, for context.
    public static let contextLines = 3
    /// A band costs a row of its own and a click, so it has to hide more than
    /// this to be worth it.
    public static let minimumHidden = 4

    /// Both halves present and unchanged. A row with one side missing is part
    /// of a change even though neither half is marked as one.
    public static func isUnchanged(_ row: SideBySideRow) -> Bool {
        row.left?.kind == .context && row.right?.kind == .context
    }

    /// - Parameter pinned: rows that must stay visible whatever else happens —
    ///   a line carrying a review comment or a finding is the reason the reader
    ///   is here, and folding it away would hide the conversation.
    public static func compute(rows: [SideBySideRow],
                               pinned: Set<Int> = [],
                               contextLines: Int = contextLines,
                               minimumHidden: Int = minimumHidden) -> [CollapsedRegion] {
        guard !rows.isEmpty else { return [] }
        var regions: [CollapsedRegion] = []
        var index = 0
        var nextID = 0

        while index < rows.count {
            guard isUnchanged(rows[index]), !pinned.contains(rows[index].id) else {
                index += 1
                continue
            }
            let start = index
            while index < rows.count, isUnchanged(rows[index]), !pinned.contains(rows[index].id) {
                index += 1
            }
            let end = index - 1

            // Nothing precedes the first run and nothing follows the last, so
            // there is no change for those lines to be context for.
            let keepBefore = start == 0 ? 0 : contextLines
            let keepAfter = end == rows.count - 1 ? 0 : contextLines
            let hiddenStart = start + keepBefore
            let hiddenEnd = end - keepAfter
            guard hiddenStart <= hiddenEnd, hiddenEnd - hiddenStart + 1 >= minimumHidden else {
                continue
            }
            regions.append(CollapsedRegion(id: nextID, range: hiddenStart...hiddenEnd))
            nextID += 1
        }
        return regions
    }
}
