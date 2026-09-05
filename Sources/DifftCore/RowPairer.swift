public struct SideBySideRow: Equatable, Identifiable, Sendable {
    public let id: Int
    public let left: DiffLine?
    public let right: DiffLine?
    /// The line this one replaced, or was replaced by.
    ///
    /// Side-by-side carries both halves in the row itself, so word-level
    /// emphasis can diff them directly. Unified splits a replacement across
    /// two rows and used to drop the other side entirely, which is why
    /// emphasis never appeared there. This keeps the counterpart so both
    /// layouts can highlight the same spans.
    public let counterpart: DiffLine?

    public init(id: Int, left: DiffLine?, right: DiffLine?, counterpart: DiffLine? = nil) {
        self.id = id; self.left = left; self.right = right
        self.counterpart = counterpart
    }

    /// The old/new pair to diff for word-level emphasis, in that order, or nil
    /// when this row is not part of a replacement.
    public var emphasisPair: (old: String, new: String)? {
        if let l = left, let r = right, l.kind == .deletion, r.kind == .addition {
            return (l.text, r.text)          // side-by-side: both halves present
        }
        guard let other = counterpart else { return nil }
        if let l = left, l.kind == .deletion { return (l.text, other.text) }
        if let r = right, r.kind == .addition { return (other.text, r.text) }
        return nil
    }
}

public enum RowPairer {
    public static func rows(for hunks: [Hunk]) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        var nextID = 0
        func emit(_ l: DiffLine?, _ r: DiffLine?) {
            rows.append(SideBySideRow(id: nextID, left: l, right: r)); nextID += 1
        }

        for hunk in hunks {
            var i = 0
            let lines = hunk.lines
            while i < lines.count {
                let line = lines[i]
                switch line.kind {
                case .context:
                    emit(line, line); i += 1
                case .deletion, .addition:
                    var dels: [DiffLine] = [], adds: [DiffLine] = []
                    while i < lines.count, lines[i].kind == .deletion { dels.append(lines[i]); i += 1 }
                    while i < lines.count, lines[i].kind == .addition { adds.append(lines[i]); i += 1 }
                    for j in 0..<max(dels.count, adds.count) {
                        emit(j < dels.count ? dels[j] : nil, j < adds.count ? adds[j] : nil)
                    }
                }
            }
        }
        return rows
    }
}

extension RowPairer {
    public static func unifiedRows(for hunks: [Hunk]) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        var nextID = 0
        for hunk in hunks {
            var i = 0
            let lines = hunk.lines
            while i < lines.count {
                let line = lines[i]
                switch line.kind {
                case .context:
                    rows.append(SideBySideRow(id: nextID, left: line, right: line))
                    nextID += 1
                    i += 1
                case .deletion, .addition:
                    // Collect the replacement block so each row can keep a
                    // reference to its opposite number, paired index-wise the
                    // same way side-by-side pairs them.
                    var dels: [DiffLine] = [], adds: [DiffLine] = []
                    while i < lines.count, lines[i].kind == .deletion { dels.append(lines[i]); i += 1 }
                    while i < lines.count, lines[i].kind == .addition { adds.append(lines[i]); i += 1 }
                    for (j, del) in dels.enumerated() {
                        rows.append(SideBySideRow(id: nextID, left: del, right: nil,
                                                  counterpart: j < adds.count ? adds[j] : nil))
                        nextID += 1
                    }
                    for (j, add) in adds.enumerated() {
                        rows.append(SideBySideRow(id: nextID, left: nil, right: add,
                                                  counterpart: j < dels.count ? dels[j] : nil))
                        nextID += 1
                    }
                }
            }
        }
        return rows
    }
}
