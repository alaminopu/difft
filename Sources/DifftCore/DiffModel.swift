public enum LineKind: Equatable, Sendable { case context, addition, deletion }

public struct DiffLine: Equatable, Sendable {
    public let kind: LineKind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String
    public init(kind: LineKind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind; self.oldNumber = oldNumber; self.newNumber = newNumber; self.text = text
    }
}

/// Which gutter a `DiffLine` is being rendered in, for line-number display.
public enum GutterSide: Sendable {
    case left, right, unified
}

extension DiffLine {
    /// The line number to display in the given gutter side.
    /// `.left` shows the old-file number, `.right` shows the new-file number,
    /// `.unified` shows old (falling back to new) as a single column would.
    public func gutterNumber(for side: GutterSide) -> Int? {
        switch side {
        case .left: return oldNumber
        case .right: return newNumber
        case .unified: return oldNumber ?? newNumber
        }
    }
}

public struct Hunk: Equatable, Sendable {
    public let header: String
    public let lines: [DiffLine]
    public init(header: String, lines: [DiffLine]) { self.header = header; self.lines = lines }
}

public enum FileChangeKind: Equatable, Sendable {
    case modified, added, deleted, binary
    case renamed(from: String)
}

public struct FileDiff: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let kind: FileChangeKind
    public let hunks: [Hunk]

    /// Counted once at construction rather than derived on each access.
    ///
    /// The file tree reads these several times per row and the PR overview
    /// sums them across every file, on every body evaluation. As computed
    /// properties — each a `flatMap` allocating an array of every line in the
    /// file — that cost ~10ms per sidebar pass on a 71-file PR. With
    /// full-context diffs a FileDiff holds the whole file, not just the
    /// changed hunks, so the walk is over everything.
    public let additions: Int
    public let deletions: Int
    /// Widest line number the gutter has to show, so its width can be derived
    /// from the file rather than guessed at a fixed size.
    public let maxLineNumber: Int

    public init(path: String, kind: FileChangeKind, hunks: [Hunk]) {
        self.path = path; self.kind = kind; self.hunks = hunks
        var adds = 0, dels = 0, maxLine = 0
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .addition: adds += 1
                case .deletion: dels += 1
                case .context: break
                }
                maxLine = max(maxLine, line.oldNumber ?? 0, line.newNumber ?? 0)
            }
        }
        self.additions = adds; self.deletions = dels; self.maxLineNumber = maxLine
    }
}
