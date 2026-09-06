import XCTest
@testable import DifftServices

final class VerifiedFindingsTests: XCTestCase {
    private func wrap(_ json: String) -> String { "Checked them.\n\n```json\n\(json)\n```" }

    /// The verification pass exists to throw candidates out. Anything it
    /// rejects, or silently omits, must not reach the reader.
    func testRejectedAndOmittedCandidatesAreDropped() {
        let survivors = FindingsParser.parseVerified(wrap("""
        [
          {"index": 0, "verdict": "confirmed", "severity": "high", "category": "crash",
           "file": "a.swift", "line": 12, "explanation": "Force unwrap of a nil path",
           "failureScenario": "An empty argv reaches it and the process traps."},
          {"index": 1, "verdict": "rejected", "severity": "high",
           "file": "b.swift", "line": 3, "explanation": "Not actually a bug",
           "failureScenario": "none"},
          {"index": 2, "verdict": "plausible", "severity": "medium", "category": "correctness",
           "file": "c.swift", "line": 44, "explanation": "Off-by-one on the last page",
           "failureScenario": "A total that is an exact multiple of the page size."}
        ]
        """))
        XCTAssertEqual(survivors.count, 2)
        XCTAssertEqual(survivors.map(\.file), ["a.swift", "c.swift"])
        XCTAssertEqual(survivors.first?.confidence, .confirmed)
        XCTAssertEqual(survivors.last?.confidence, .plausible)
    }

    /// Dropping everything is a legitimate outcome, not a parse failure.
    func testEmptyVerdictListMeansNothingSurvived() {
        XCTAssertTrue(FindingsParser.parseVerified(wrap("[]")).isEmpty)
    }

    /// An unrecognised verdict is not a licence to promote the finding.
    func testUnknownVerdictDegradesToPlausible() {
        let s = FindingsParser.parseVerified(wrap("""
        [{"verdict": "probably?", "severity": "low", "file": "a.swift", "line": 1,
          "explanation": "Something", "failureScenario": "x"}]
        """))
        XCTAssertEqual(s.first?.confidence, .plausible)
    }

    /// A finding with no location cannot be opened, and one with no text says
    /// nothing — neither is worth a row.
    func testUnusableEntriesAreDropped() {
        let s = FindingsParser.parseVerified(wrap("""
        [{"verdict": "confirmed", "file": "", "line": 1, "explanation": "No file"},
         {"verdict": "confirmed", "file": "a.swift", "line": 1, "explanation": ""}]
        """))
        XCTAssertTrue(s.isEmpty)
    }

    /// The finder's own output goes through the plain parser, and a line
    /// written as a string still resolves.
    func testCandidateParsingIsTolerant() {
        let f = FindingsParser.parse(wrap("""
        [{"severity": "high", "file": "a.swift", "line": "17",
          "explanation": "Bad", "failureScenario": "Empty input"}]
        """))
        XCTAssertEqual(f.first?.line, 17)
        XCTAssertEqual(f.first?.failureScenario, "Empty input")
        // Not yet verified, so it must not claim to be.
        XCTAssertEqual(f.first?.confidence, .plausible)
    }

    func testSeverityOrdering() {
        let high = Finding(severity: "high", file: "a", line: 1, explanation: "e")
        let low = Finding(severity: "low", file: "a", line: 1, explanation: "e")
        let odd = Finding(severity: "wat", file: "a", line: 1, explanation: "e")
        XCTAssertLessThan(high.severityRank, low.severityRank)
        XCTAssertEqual(odd.severityRank, low.severityRank)
    }
}
