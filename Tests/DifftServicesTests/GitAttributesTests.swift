import XCTest
@testable import DifftServices

final class GitAttributesTests: XCTestCase {
    /// Exactly what `git check-attr -z diff linguist-generated -- …` writes:
    /// flat NUL-separated triples, no line structure.
    private let real = "gen.txt\0diff\0unspecified\0gen.txt\0linguist-generated\0true\0"
        + "blob.txt\0diff\0unset\0blob.txt\0linguist-generated\0unspecified\0"
        + "normal.txt\0diff\0unspecified\0normal.txt\0linguist-generated\0unspecified\0"

    func testReadsBothAttributes() {
        let attrs = GitAttributes.parse(real)
        XCTAssertEqual(attrs["gen.txt"], GitFileAttributes(isGenerated: true, diffSuppressed: false))
        // Only files with something notable get an entry, so the caller can
        // skip the recovery pass entirely when the map comes back empty.
        XCTAssertNil(attrs["normal.txt"])
    }

    /// `-diff` is why these files looked unviewable: git prints "Binary files
    /// … differ" for ordinary text, so there was no patch to parse. A path the
    /// repository excludes from diffs is generated output by intent.
    func testDiffUnsetMarksSuppressedAndGenerated() {
        let attrs = GitAttributes.parse(real)
        XCTAssertEqual(attrs["blob.txt"], GitFileAttributes(isGenerated: true, diffSuppressed: true))
    }

    /// Paths with spaces are the reason for -z in the first place.
    func testPathsWithSpacesSurvive() {
        let attrs = GitAttributes.parse("a b/c d.lock\0diff\0unset\0")
        XCTAssertEqual(attrs["a b/c d.lock"]?.diffSuppressed, true)
    }

    /// A file whose attributes cannot be read should render as an ordinary
    /// file, not fail the open.
    func testGarbageYieldsNothingRatherThanThrowing() {
        XCTAssertTrue(GitAttributes.parse("").isEmpty)
        XCTAssertTrue(GitAttributes.parse("dangling\0pair\0").isEmpty)
        XCTAssertTrue(GitAttributes.parse("\0\0\0").isEmpty)
    }

    func testUnknownValuesAreNotGenerated() {
        let attrs = GitAttributes.parse("x\0linguist-generated\0unspecified\0x\0diff\0set\0")
        XCTAssertTrue(attrs.isEmpty)
    }
}

final class PRSearchQueryTests: XCTestCase {
    func testRecognisesTheFormsPeopleType() {
        XCTAssertEqual(PRSearchQuery.number(in: "6022"), 6022)
        XCTAssertEqual(PRSearchQuery.number(in: "#6022"), 6022)
        XCTAssertEqual(PRSearchQuery.number(in: "  #6022 "), 6022)
        XCTAssertEqual(PRSearchQuery.number(in: "https://github.com/a/b/pull/6022"), 6022)
        XCTAssertEqual(PRSearchQuery.number(in: "https://github.com/a/b/pull/6022/files"), nil)
    }

    func testWordsAreNotNumbers() {
        XCTAssertNil(PRSearchQuery.number(in: "formula"))
        XCTAssertNil(PRSearchQuery.number(in: "author:alice"))
        XCTAssertNil(PRSearchQuery.number(in: ""))
        XCTAssertNil(PRSearchQuery.number(in: "#"))
        XCTAssertNil(PRSearchQuery.number(in: "0"))
        XCTAssertNil(PRSearchQuery.number(in: "12a"))
        // Not a plausible PR number, and not worth an Int overflow.
        XCTAssertNil(PRSearchQuery.number(in: "9999999999999999999999"))
    }

    /// A bare number handed to GitHub's text search matches every PR whose
    /// body mentions it; the number is looked up directly instead.
    func testANumberIsNotSentAsSearchTerms() {
        XCTAssertEqual(PRSearchQuery.terms(in: "#6022"), "")
        XCTAssertEqual(PRSearchQuery.terms(in: "formula"), "formula")
    }
    /// Two `author:` qualifiers side by side are ANDed, and no PR has two
    /// authors — that spelling always returns nothing. They have to be an
    /// explicit OR.
    func testSeveralAuthorsBecomeAParenthesisedOr() {
        XCTAssertEqual(PRSearchQuery.full(query: "", authors: ["bob", "alice"]),
                       "(author:alice OR author:bob)")
    }

    func testOneAuthorNeedsNoParentheses() {
        XCTAssertEqual(PRSearchQuery.full(query: "", authors: ["alice"]), "author:alice")
    }

    /// Parenthesised, so the text terms apply across every author rather than
    /// binding to the first one.
    func testTextAndAuthorsCombine() {
        XCTAssertEqual(PRSearchQuery.full(query: "formula", authors: ["b", "a"]),
                       "formula (author:a OR author:b)")
        XCTAssertEqual(PRSearchQuery.full(query: "  formula  ", authors: []), "formula")
    }

    /// A number is still looked up directly, but the author filter has to
    /// survive alongside it.
    func testANumberDropsTheTextButKeepsTheAuthors() {
        XCTAssertEqual(PRSearchQuery.full(query: "#6022", authors: ["alice"]), "author:alice")
        XCTAssertEqual(PRSearchQuery.full(query: "#6022", authors: []), "")
    }

    func testBlankAuthorsAreIgnored() {
        XCTAssertEqual(PRSearchQuery.full(query: "", authors: ["", "  ", "alice", "alice"]),
                       "author:alice")
    }

}
