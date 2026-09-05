import XCTest
@testable import DifftCore

final class RowPairerTests: XCTestCase {
    private func line(_ kind: LineKind, _ text: String) -> DiffLine {
        DiffLine(kind: kind, oldNumber: kind == .addition ? nil : 1, newNumber: kind == .deletion ? nil : 1, text: text)
    }

    func testContextPairsBothSides() {
        let hunk = Hunk(header: "@@", lines: [line(.context, "a")])
        let rows = RowPairer.rows(for: [hunk])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].left?.text, "a")
        XCTAssertEqual(rows[0].right?.text, "a")
    }

    func testBalancedChangeBlockPairsIndexWise() {
        let hunk = Hunk(header: "@@", lines: [
            line(.deletion, "d1"), line(.deletion, "d2"),
            line(.addition, "a1"), line(.addition, "a2"),
        ])
        let rows = RowPairer.rows(for: [hunk])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].left?.text, "d1"); XCTAssertEqual(rows[0].right?.text, "a1")
        XCTAssertEqual(rows[1].left?.text, "d2"); XCTAssertEqual(rows[1].right?.text, "a2")
    }

    func testUnbalancedBlockFillsNil() {
        let hunk = Hunk(header: "@@", lines: [
            line(.deletion, "d1"),
            line(.addition, "a1"), line(.addition, "a2"), line(.addition, "a3"),
        ])
        let rows = RowPairer.rows(for: [hunk])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].left?.text, "d1"); XCTAssertEqual(rows[0].right?.text, "a1")
        XCTAssertNil(rows[1].left); XCTAssertEqual(rows[1].right?.text, "a2")
        XCTAssertNil(rows[2].left); XCTAssertEqual(rows[2].right?.text, "a3")
    }

    func testAdditionOnlyBlock() {
        let hunk = Hunk(header: "@@", lines: [line(.context, "c"), line(.addition, "a1")])
        let rows = RowPairer.rows(for: [hunk])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[1].left)
        XCTAssertEqual(rows[1].right?.text, "a1")
    }

    func testIdsSequentialAcrossHunks() {
        let h1 = Hunk(header: "@@", lines: [line(.context, "x")])
        let h2 = Hunk(header: "@@", lines: [line(.context, "y")])
        let rows = RowPairer.rows(for: [h1, h2])
        XCTAssertEqual(rows.map(\.id), [0, 1])
    }
}
