import XCTest
@testable import DifftCore

/// Deletions and additions are paired by index, not similarity, so a rewritten
/// block can put two unrelated lines opposite each other. Emphasising those
/// paints most of both lines and buries the code.
final class IntralineSimilarityTests: XCTestCase {
    private func isEmphasised(_ old: String, _ new: String) -> Bool {
        let r = IntralineDiff.changedRanges(old: old, new: new)
        return !r.old.isEmpty || !r.new.isEmpty
    }

    // MARK: genuine edits — must keep emphasis

    func testConstantSwappedIn() {
        XCTAssertTrue(isEmphasised("        timeout=10,",
                                   "        timeout=SLACK_REQUEST_TIMEOUT_SECONDS,"))
    }

    func testIdentifierRenamed() {
        XCTAssertTrue(isEmphasised("        response_data = response.json()",
                                   "        response_body = response.json()"))
    }

    func testArgumentAdded() {
        XCTAssertTrue(isEmphasised("    def send(self, message):",
                                   "    def send(self, message, timeout=30):"))
    }

    func testStringLiteralChanged() {
        XCTAssertTrue(isEmphasised(#"    raise ValueError("bad input")"#,
                                   #"    raise ValueError("invalid input provided")"#))
    }

    // MARK: coincidental pairs — must suppress

    /// Both from a real screenshot where the emphasis made the line unreadable.
    func testUnrelatedRaiseVersusComment() {
        XCTAssertFalse(isEmphasised(
            "        raise UnexpectedDispatchException(str(e)) from e",
            "            # Not str(e) - requests names the whole URL, and this one's query"))
    }

    func testUnrelatedLoggerVersusComment() {
        XCTAssertFalse(isEmphasised(
            #"        logger.exception("Error while dispatching HTTP request")"#,
            "            # Not logger.exception - loguru prints the frame locals, and this"))
    }

    func testCompletelyDifferentStatements() {
        XCTAssertFalse(isEmphasised("    return self.cached_value",
                                    "    for item in collection.filter(active=True):"))
    }

    // MARK: edges

    func testIdenticalLinesHaveNothingToEmphasise() {
        XCTAssertFalse(isEmphasised("let x = 1", "let x = 1"))
    }

    func testEmptyOldSideDoesNotCrash() {
        _ = IntralineDiff.changedRanges(old: "", new: "let x = 1")
        _ = IntralineDiff.changedRanges(old: "let x = 1", new: "")
    }

    /// The guard is on the lesser side: a short line replaced by a long one is
    /// still a real edit as long as the short side is mostly preserved.
    func testShortLinePreservedInsideALongerOneStillEmphasises() {
        XCTAssertTrue(isEmphasised("    x = 1",
                                   "    x = 1 if condition else fallback_value_here"))
    }
}
