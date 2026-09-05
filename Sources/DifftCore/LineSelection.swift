public struct LineSelection: Equatable, Sendable {
    public var anchor: Int
    public var head: Int
    public var range: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }
    public init(anchor: Int, head: Int) { self.anchor = anchor; self.head = head }
}

public enum SelectionLogic {
    public static func click(current: LineSelection?, rowID: Int, extending: Bool) -> LineSelection {
        if extending, let cur = current { return LineSelection(anchor: cur.anchor, head: rowID) }
        return LineSelection(anchor: rowID, head: rowID)
    }

    public static func selectedText(rows: [SideBySideRow], selection: LineSelection) -> String {
        rows.filter { selection.range.contains($0.id) }.compactMap { row -> String? in
            guard let line = row.right ?? row.left else { return nil }
            let sign = line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " "
            return sign + line.text
        }.joined(separator: "\n")
    }

    public static func contextChip(path: String, rows: [SideBySideRow], selection: LineSelection) -> String {
        let selected = rows.filter { selection.range.contains($0.id) }
        let numbers = selected.compactMap { ($0.right ?? $0.left).flatMap { $0.newNumber ?? $0.oldNumber } }
        guard let first = numbers.first, let last = numbers.last else { return path }
        return "\(path):\(first)-\(last)"
    }
}
