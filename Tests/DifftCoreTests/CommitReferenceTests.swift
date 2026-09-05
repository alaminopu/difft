import XCTest
@testable import DifftCore

final class CommitReferenceTests: XCTestCase {
    private func shas(_ text: String) -> [String] {
        let chars = Array(text)
        return CommitReference.ranges(in: text).map { String(chars[$0]) }
    }

    /// The case that prompted this, verbatim from a review comment.
    func testFindsTwoShasInASentence() {
        XCTAssertEqual(shas("Fixed in d59f520cc and b32db62bf."),
                       ["d59f520cc", "b32db62bf"])
    }

    func testFindsAFullLengthSha() {
        let sha = "8ecb35dc9ae5f7d20e7ac70d125ae08b51058c6c"
        XCTAssertEqual(shas("see \(sha) for context"), [sha])
    }

    func testFindsAShaAtTheStartAndEndOfText() {
        XCTAssertEqual(shas("d59f520cc"), ["d59f520cc"])
        XCTAssertEqual(shas("reverted d59f520cc"), ["d59f520cc"])
    }

    // MARK: things that look like SHAs but are not

    /// Review comments are full of line numbers and counts, and a run of
    /// digits is valid hex.
    func testPlainNumbersAreNotShas() {
        XCTAssertTrue(shas("see line 1234567 and 99999999").isEmpty)
    }

    func testTooShortIsNotASha() {
        XCTAssertTrue(shas("abc123 is short").isEmpty)
    }

    func testTooLongIsNotASha() {
        XCTAssertTrue(shas(String(repeating: "a", count: 41)).isEmpty)
    }

    func testUppercaseIsNotASha() {
        XCTAssertTrue(shas("DEADBEEF12 is a constant").isEmpty)
    }

    func testNonHexWordsAreNotShas() {
        XCTAssertTrue(shas("the response_data variable").isEmpty)
    }

    /// A hex run inside a longer identifier is part of that identifier.
    func testHexInsideAnIdentifierIsNotASha() {
        XCTAssertTrue(shas("call abc123def_handler now").isEmpty)
        XCTAssertTrue(shas("var x = deadbeef1z").isEmpty)
    }

    func testShaFollowedByPunctuationIsFound() {
        XCTAssertEqual(shas("(see d59f520cc), then"), ["d59f520cc"])
        XCTAssertEqual(shas("commit d59f520cc: fixes it"), ["d59f520cc"])
    }

    func testEmptyTextHasNoShas() {
        XCTAssertTrue(shas("").isEmpty)
    }

    func testRangesPointAtTheRightCharacters() {
        let text = "Fixed in d59f520cc."
        let r = CommitReference.ranges(in: text)
        XCTAssertEqual(r, [9..<18])
    }
}

extension CommitReferenceTests {
    func testLinkRoundTripsTheSha() throws {
        let url = try XCTUnwrap(CommitReference.url(sha: "d59f520cc"))
        XCTAssertEqual(CommitReference.sha(from: url), "d59f520cc")
    }

    /// Ordinary links must be left to the system, not swallowed.
    func testOrdinaryURLsCarryNoSha() throws {
        let https = try XCTUnwrap(URL(string: "https://github.com/a/b/commit/d59f520cc"))
        XCTAssertNil(CommitReference.sha(from: https))
        let mailto = try XCTUnwrap(URL(string: "mailto:someone@example.com"))
        XCTAssertNil(CommitReference.sha(from: mailto))
    }

    func testFullLengthShaRoundTrips() throws {
        let sha = "8ecb35dc9ae5f7d20e7ac70d125ae08b51058c6c"
        let url = try XCTUnwrap(CommitReference.url(sha: sha))
        XCTAssertEqual(CommitReference.sha(from: url), sha)
    }
}
