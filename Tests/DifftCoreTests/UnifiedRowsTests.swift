import XCTest
@testable import DifftCore

final class UnifiedRowsTests: XCTestCase {
    func testUnifiedPreservesOrderOneRowPerLine() {
        let hunk = Hunk(header: "@@", lines: [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "c"),
            DiffLine(kind: .deletion, oldNumber: 2, newNumber: nil, text: "d"),
            DiffLine(kind: .addition, oldNumber: nil, newNumber: 2, text: "a"),
        ])
        let rows = RowPairer.unifiedRows(for: [hunk])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].left?.text, "c"); XCTAssertEqual(rows[0].right?.text, "c")
        XCTAssertEqual(rows[1].left?.text, "d"); XCTAssertNil(rows[1].right)
        XCTAssertNil(rows[2].left); XCTAssertEqual(rows[2].right?.text, "a")
    }
}
