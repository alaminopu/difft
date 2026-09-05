public struct SideBySideRow: Equatable, Identifiable, Sendable {
    public let id: Int
    public let left: DiffLine?
    public let right: DiffLine?
    public init(id: Int, left: DiffLine?, right: DiffLine?) {
        self.id = id; self.left = left; self.right = right
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
            for line in hunk.lines {
                switch line.kind {
                case .context: rows.append(SideBySideRow(id: nextID, left: line, right: line))
                case .deletion: rows.append(SideBySideRow(id: nextID, left: line, right: nil))
                case .addition: rows.append(SideBySideRow(id: nextID, left: nil, right: line))
                }
                nextID += 1
            }
        }
        return rows
    }
}
