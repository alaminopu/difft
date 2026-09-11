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

    /// The rows a selection covers.
    ///
    /// Rows carry consecutive ids in list order, so the selection is a slice
    /// rather than a search. Filtering the whole array was O(file) per call,
    /// and `.copyable` calls it on every body pass while a selection exists —
    /// which, during a drag-select, is every mouse-move frame over a
    /// full-context diff holding the entire file.
    static func slice(_ rows: [SideBySideRow], _ selection: LineSelection) -> ArraySlice<SideBySideRow> {
        let range = selection.range
        guard let first = rows.first?.id else { return [] }
        let low = range.lowerBound - first
        let high = range.upperBound - first
        guard high >= 0, low < rows.count else { return [] }
        let lower = max(0, low)
        let upper = min(rows.count - 1, high)
        guard lower <= upper else { return [] }
        let candidate = rows[lower...upper]
        // Ids are consecutive in every diff the pairer produces; if that ever
        // stops holding, fall back rather than copying the wrong lines.
        guard candidate.allSatisfy({ range.contains($0.id) }) else {
            return ArraySlice(rows.filter { range.contains($0.id) })
        }
        return candidate
    }

    public static func selectedText(rows: [SideBySideRow], selection: LineSelection) -> String {
        slice(rows, selection).compactMap { row -> String? in
            guard let line = row.right ?? row.left else { return nil }
            let sign = line.kind == .addition ? "+" : line.kind == .deletion ? "-" : " "
            return sign + line.text
        }.joined(separator: "\n")
    }

    public static func contextChip(path: String, rows: [SideBySideRow], selection: LineSelection) -> String {
        let selected = slice(rows, selection)
        let numbers = selected.compactMap { ($0.right ?? $0.left).flatMap { $0.newNumber ?? $0.oldNumber } }
        guard let first = numbers.first, let last = numbers.last else { return path }
        return "\(path):\(first)-\(last)"
    }
}
