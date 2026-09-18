import XCTest
@testable import DifftCore

final class CollapsedRegionsTests: XCTestCase {
    private func context(_ id: Int) -> SideBySideRow {
        let line = DiffLine(kind: .context, oldNumber: id, newNumber: id, text: "ctx\(id)")
        return SideBySideRow(id: id, left: line, right: line)
    }

    private func added(_ id: Int) -> SideBySideRow {
        SideBySideRow(id: id, left: nil,
                      right: DiffLine(kind: .addition, oldNumber: nil, newNumber: id, text: "new"))
    }

    private func rows(_ pattern: String) -> [SideBySideRow] {
        pattern.enumerated().map { $1 == "." ? context($0) : added($0) }
    }

    /// The case this exists for: a full-context diff of a file with one small
    /// change in the middle.
    func testFoldsTheLongUnchangedRunsAroundAChange() {
        // 10 context, 1 change, 10 context.
        let r = rows(String(repeating: ".", count: 10) + "+" + String(repeating: ".", count: 10))
        let regions = CollapsedRegions.compute(rows: r)
        XCTAssertEqual(regions.count, 2)
        // Leading run keeps nothing above (nothing precedes it) and 3 below.
        XCTAssertEqual(regions[0].range, 0...6)
        // Trailing run keeps 3 above and nothing below.
        XCTAssertEqual(regions[1].range, 14...20)
    }

    /// A run too short to be worth a band is left alone — the band costs a row
    /// and a click of its own.
    func testLeavesShortRunsAlone() {
        // 3 context either side of a change: nothing to hide.
        XCTAssertTrue(CollapsedRegions.compute(rows: rows("...+...")).isEmpty)
        // 6 between two changes keeps 3+3, hiding zero.
        XCTAssertTrue(CollapsedRegions.compute(rows: rows("+......+")).isEmpty)
        // 9 between two changes hides 3 — still under the minimum.
        XCTAssertTrue(CollapsedRegions.compute(rows: rows("+.........+")).isEmpty)
        // 10 hides 4, which is worth it.
        XCTAssertEqual(CollapsedRegions.compute(rows: rows("+..........+")).first?.range, 4...7)
    }

    /// A line carrying a comment or a finding is the reason the reader opened
    /// the file; folding it away would hide the conversation.
    func testNeverFoldsAPinnedRow() {
        let r = rows(String(repeating: ".", count: 30))
        let unpinned = CollapsedRegions.compute(rows: r)
        XCTAssertEqual(unpinned.count, 1)
        XCTAssertTrue(unpinned[0].range.contains(15))

        let pinned = CollapsedRegions.compute(rows: r, pinned: [15])
        XCTAssertFalse(pinned.contains { $0.range.contains(15) })
        // The row splits the run in two, each folded on its own merits.
        XCTAssertEqual(pinned.count, 2)
    }

    /// A file with no changes at all is still a file — it folds to one band
    /// rather than to nothing.
    func testAnEntirelyUnchangedFileFoldsWhole() {
        let regions = CollapsedRegions.compute(rows: rows(String(repeating: ".", count: 40)))
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].range, 0...39)
    }

    func testRowsWithOneSideMissingCountAsChanged() {
        // A filler row has no left half; it is part of a change even though
        // neither half is marked as one.
        XCTAssertFalse(CollapsedRegions.isUnchanged(added(1)))
        XCTAssertTrue(CollapsedRegions.isUnchanged(context(1)))
    }

    func testEmptyInput() {
        XCTAssertTrue(CollapsedRegions.compute(rows: []).isEmpty)
    }
}
