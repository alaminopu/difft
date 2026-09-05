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
    public var additions: Int { hunks.flatMap(\.lines).filter { $0.kind == .addition }.count }
    public var deletions: Int { hunks.flatMap(\.lines).filter { $0.kind == .deletion }.count }
    public init(path: String, kind: FileChangeKind, hunks: [Hunk]) {
        self.path = path; self.kind = kind; self.hunks = hunks
    }
}
