import XCTest
@testable import DifftCore

final class IntralineDiffTests: XCTestCase {
    func testSingleWordChange() {
        let r = IntralineDiff.changedRanges(old: "DEBUG = False", new: "DEBUG = True")
        XCTAssertEqual(r.old, [8..<13])   // "False"
        XCTAssertEqual(r.new, [8..<12])   // "True"
    }

    func testIdenticalStringsNoRanges() {
        let r = IntralineDiff.changedRanges(old: "same", new: "same")
        XCTAssertTrue(r.old.isEmpty); XCTAssertTrue(r.new.isEmpty)
    }

    /// Two lines with nothing in common get no emphasis: the row tint already
    /// says "this changed", and marking every character of both is what made
    /// rewritten blocks unreadable. Previously this returned the full range of
    /// each side. See IntralineSimilarityTests for the reasoning and measured
    /// thresholds.
    func testCompletelyDifferentIsNotEmphasised() {
        let r = IntralineDiff.changedRanges(old: "abc", new: "xyz")
        XCTAssertTrue(r.old.isEmpty); XCTAssertTrue(r.new.isEmpty)
    }

    func testInsertionMergesAdjacent() {
        let r = IntralineDiff.changedRanges(old: "let a = 1", new: "let ab = 12")
        XCTAssertEqual(r.old, [4..<5, 8..<9])
        XCTAssertEqual(r.new, [4..<6, 9..<11])
    }

    func testEmptyOldSide() {
        let r = IntralineDiff.changedRanges(old: "", new: "new line")
        XCTAssertTrue(r.old.isEmpty)
        XCTAssertEqual(r.new, [0..<8])
    }
}
