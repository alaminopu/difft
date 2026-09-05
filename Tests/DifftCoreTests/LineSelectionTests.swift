import XCTest
@testable import DifftCore

final class LineSelectionTests: XCTestCase {
    private func row(_ id: Int, kind: LineKind, old: Int?, new: Int?, _ text: String) -> SideBySideRow {
        let line = DiffLine(kind: kind, oldNumber: old, newNumber: new, text: text)
        return SideBySideRow(id: id, left: kind == .addition ? nil : line, right: kind == .deletion ? nil : line)
    }

    func testClickStartsSelection() {
        let sel = SelectionLogic.click(current: nil, rowID: 5, extending: false)
        XCTAssertEqual(sel.range, 5...5)
    }

    func testShiftClickExtends() {
        var sel = SelectionLogic.click(current: nil, rowID: 5, extending: false)
        sel = SelectionLogic.click(current: sel, rowID: 2, extending: true)
        XCTAssertEqual(sel.range, 2...5)
    }

    func testPlainClickResets() {
        var sel = SelectionLogic.click(current: LineSelection(anchor: 1, head: 9), rowID: 4, extending: false)
        XCTAssertEqual(sel.range, 4...4)
        sel = SelectionLogic.click(current: sel, rowID: 6, extending: true)
        XCTAssertEqual(sel.range, 4...6)
    }

    func testSelectedTextPrefixesSigns() {
        let rows = [
            row(0, kind: .context, old: 1, new: 1, "ctx"),
            row(1, kind: .deletion, old: 2, new: nil, "gone"),
            row(2, kind: .addition, old: nil, new: 2, "added"),
        ]
        let text = SelectionLogic.selectedText(rows: rows, selection: LineSelection(anchor: 0, head: 2))
        XCTAssertEqual(text, " ctx\n-gone\n+added")
    }

    func testContextChip() {
        let rows = [
            row(0, kind: .context, old: 10, new: 10, "a"),
            row(1, kind: .addition, old: nil, new: 11, "b"),
        ]
        let chip = SelectionLogic.contextChip(path: "src/f.swift", rows: rows, selection: LineSelection(anchor: 0, head: 1))
        XCTAssertEqual(chip, "src/f.swift:10-11")
    }
}
