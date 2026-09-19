import XCTest
@testable import DifftCore

final class FuzzyMatchTests: XCTestCase {
    func testRejectsWhenCharactersAreMissingOrOutOfOrder() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", candidate: "src/air/form/main.py"))
        XCTAssertNil(FuzzyMatch.score(query: "niam", candidate: "main.py"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.score(query: "", candidate: "anything"), 0)
        XCTAssertEqual(FuzzyMatch.score(query: "  ", candidate: "anything"), 0)
    }

    /// The point of the scoring: the file name beats a folder that merely
    /// contains the same letters.
    func testFileNameOutranksDirectoryMatch() {
        let files = ["docs/maintenance/index.md", "src/air/form/main.py"]
        XCTAssertEqual(FuzzyMatch.rank(files, query: "main") { $0 }.first, "src/air/form/main.py")
    }

    func testFolderInitialNarrowsBetweenSameNamedFiles() {
        let files = ["src/air/field/main.py", "src/air/form/main.py", "src/air/model/main.py"]
        XCTAssertEqual(FuzzyMatch.rank(files, query: "mod main") { $0 }.first, "src/air/model/main.py")
    }

    func testIsCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score(query: "README", candidate: "docs/readme.md"))
    }

    func testShorterPathWinsATie() {
        let files = ["a/b/c/test_form.py", "test_form.py"]
        XCTAssertEqual(FuzzyMatch.rank(files, query: "test_form") { $0 }.first, "test_form.py")
    }

    func testSplitsTrailingLineNumber() {
        XCTAssertEqual(FuzzyMatch.splitLine("main.py:120").query, "main.py")
        XCTAssertEqual(FuzzyMatch.splitLine("main.py:120").line, 120)
        XCTAssertNil(FuzzyMatch.splitLine("main.py").line)
        XCTAssertNil(FuzzyMatch.splitLine("main.py:").line)
        XCTAssertEqual(FuzzyMatch.splitLine("main.py:abc").query, "main.py:abc")
    }
}
