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

extension UnifiedRowsTests {
    /// Unified splits a replacement across two rows. It used to drop the other
    /// side, which is why word-level emphasis never appeared in this layout.
    func testUnifiedKeepsTheCounterpartOfAReplacement() {
        let hunk = Hunk(header: "@@", lines: [
            DiffLine(kind: .deletion, oldNumber: 1, newNumber: nil, text: "let a = 1"),
            DiffLine(kind: .addition, oldNumber: nil, newNumber: 1, text: "let a = 2"),
        ])
        let rows = RowPairer.unifiedRows(for: [hunk])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].counterpart?.text, "let a = 2")
        XCTAssertEqual(rows[1].counterpart?.text, "let a = 1")
    }

    /// Both rows must diff the same pair, in old→new order, or the two halves
    /// of one replacement would highlight different spans.
    func testEmphasisPairIsOldThenNewOnBothRows() {
        let hunk = Hunk(header: "@@", lines: [
            DiffLine(kind: .deletion, oldNumber: 1, newNumber: nil, text: "old"),
            DiffLine(kind: .addition, oldNumber: nil, newNumber: 1, text: "new"),
        ])
        let rows = RowPairer.unifiedRows(for: [hunk])
        XCTAssertEqual(rows[0].emphasisPair?.old, "old")
        XCTAssertEqual(rows[0].emphasisPair?.new, "new")
        XCTAssertEqual(rows[1].emphasisPair?.old, "old")
        XCTAssertEqual(rows[1].emphasisPair?.new, "new")
    }

    /// An unmatched deletion is a plain removal, not a replacement.
    func testUnpairedLinesHaveNoCounterpart() {
        let hunk = Hunk(header: "@@", lines: [
            DiffLine(kind: .deletion, oldNumber: 1, newNumber: nil, text: "gone"),
            DiffLine(kind: .deletion, oldNumber: 2, newNumber: nil, text: "also gone"),
            DiffLine(kind: .addition, oldNumber: nil, newNumber: 1, text: "kept"),
        ])
        let rows = RowPairer.unifiedRows(for: [hunk])
        XCTAssertEqual(rows[0].counterpart?.text, "kept")
        XCTAssertNil(rows[1].counterpart, "second deletion has no matching addition")
        XCTAssertNil(rows[1].emphasisPair)
    }

    func testContextRowsAreNotAReplacement() {
        let hunk = Hunk(header: "@@", lines: [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "same"),
        ])
        XCTAssertNil(RowPairer.unifiedRows(for: [hunk])[0].emphasisPair)
    }

    /// Side-by-side carries both halves in the row, so it needs no counterpart.
    func testSideBySideDerivesTheEmphasisPairFromItsOwnHalves() {
        let hunk = Hunk(header: "@@", lines: [
            DiffLine(kind: .deletion, oldNumber: 1, newNumber: nil, text: "old"),
            DiffLine(kind: .addition, oldNumber: nil, newNumber: 1, text: "new"),
        ])
        let rows = RowPairer.rows(for: [hunk])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].emphasisPair?.old, "old")
        XCTAssertEqual(rows[0].emphasisPair?.new, "new")
    }
}

final class MaxLineNumberTests: XCTestCase {
    func testMaxLineNumberSpansBothSides() {
        let file = FileDiff(path: "a.swift", kind: .modified, hunks: [
            Hunk(header: "@@", lines: [
                DiffLine(kind: .deletion, oldNumber: 4210, newNumber: nil, text: "x"),
                DiffLine(kind: .addition, oldNumber: nil, newNumber: 9999, text: "y"),
            ]),
        ])
        XCTAssertEqual(file.maxLineNumber, 9999)
    }

    func testMaxLineNumberOfAnEmptyFileIsZero() {
        XCTAssertEqual(FileDiff(path: "a", kind: .modified, hunks: []).maxLineNumber, 0)
    }
}

/// These moved from computed properties to stored ones for performance, so
/// they need coverage that the counting itself is still right.
final class FileDiffStatsTests: XCTestCase {
    private let file = FileDiff(path: "a.swift", kind: .modified, hunks: [
        Hunk(header: "@@", lines: [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "keep"),
            DiffLine(kind: .deletion, oldNumber: 2, newNumber: nil, text: "old"),
            DiffLine(kind: .addition, oldNumber: nil, newNumber: 2, text: "new"),
            DiffLine(kind: .addition, oldNumber: nil, newNumber: 3, text: "extra"),
        ]),
        Hunk(header: "@@", lines: [
            DiffLine(kind: .deletion, oldNumber: 40, newNumber: nil, text: "gone"),
        ]),
    ])

    func testCountsSpanEveryHunk() {
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 2)
    }

    func testContextLinesCountAsNeither() {
        let onlyContext = FileDiff(path: "a", kind: .modified, hunks: [
            Hunk(header: "@@", lines: [DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "x")]),
        ])
        XCTAssertEqual(onlyContext.additions, 0)
        XCTAssertEqual(onlyContext.deletions, 0)
    }

    func testMaxLineNumberSpansHunksAndSides() {
        XCTAssertEqual(file.maxLineNumber, 40)
    }

    func testEmptyFileHasZeroedStats() {
        let empty = FileDiff(path: "a", kind: .added, hunks: [])
        XCTAssertEqual(empty.additions, 0)
        XCTAssertEqual(empty.deletions, 0)
        XCTAssertEqual(empty.maxLineNumber, 0)
    }
}
