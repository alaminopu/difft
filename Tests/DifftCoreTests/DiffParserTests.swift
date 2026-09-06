import XCTest
@testable import DifftCore

final class DiffParserTests: XCTestCase {
    func testSimpleModify() {
        let files = DiffParser.parse(Fixtures.simpleModify)
        XCTAssertEqual(files.count, 1)
        let f = files[0]
        XCTAssertEqual(f.path, "src/app.py")
        XCTAssertEqual(f.kind, .modified)
        XCTAssertEqual(f.hunks.count, 1)
        XCTAssertEqual(f.hunks[0].header, "@@ -1,4 +1,4 @@ def main")
        let lines = f.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .deletion, .addition, .context])
        XCTAssertEqual(lines[0].oldNumber, 1); XCTAssertEqual(lines[0].newNumber, 1)
        XCTAssertEqual(lines[1].oldNumber, 2); XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[2].newNumber, 2); XCTAssertNil(lines[2].oldNumber)
        XCTAssertEqual(lines[3].oldNumber, 3); XCTAssertEqual(lines[3].newNumber, 3)
        XCTAssertEqual(lines[1].text, "DEBUG = False")
        XCTAssertEqual(f.additions, 1); XCTAssertEqual(f.deletions, 1)
    }

    func testAddedFile() {
        let f = DiffParser.parse(Fixtures.addedFile)[0]
        XCTAssertEqual(f.kind, .added)
        XCTAssertEqual(f.path, "new.txt")
        XCTAssertEqual(f.additions, 2)
    }

    func testDeletedFile() {
        let f = DiffParser.parse(Fixtures.deletedFile)[0]
        XCTAssertEqual(f.kind, .deleted)
        XCTAssertEqual(f.path, "gone.txt")
    }

    func testBinaryFile() {
        let f = DiffParser.parse(Fixtures.binaryFile)[0]
        XCTAssertEqual(f.kind, .binary)
        XCTAssertEqual(f.path, "logo.png")
        XCTAssertTrue(f.hunks.isEmpty)
    }

    func testRenamedFile() {
        let f = DiffParser.parse(Fixtures.renamedFile)[0]
        XCTAssertEqual(f.kind, .renamed(from: "old_name.swift"))
        XCTAssertEqual(f.path, "new_name.swift")
        XCTAssertEqual(f.hunks.count, 1)
    }

    func testMultiHunkNumbers() {
        let f = DiffParser.parse(Fixtures.multiHunk)[0]
        XCTAssertEqual(f.hunks.count, 2)
        let h2 = f.hunks[1].lines
        XCTAssertEqual(h2[0].oldNumber, 10)
        XCTAssertEqual(h2[2].kind, .addition)
        XCTAssertEqual(h2[2].newNumber, 12)
    }

    func testMultipleFilesAndGarbageTolerance() {
        let joined = Fixtures.simpleModify + "\n" + Fixtures.binaryFile + "\n" + Fixtures.addedFile
        XCTAssertEqual(DiffParser.parse(joined).count, 3)
        XCTAssertEqual(DiffParser.parse("").count, 0)
        XCTAssertEqual(DiffParser.parse("not a diff at all").count, 0)
    }

    /// Real `gh pr diff` output ends with a trailing newline. That must not
    /// produce a phantom trailing context line (a blank row with a gutter
    /// number past the end of the file) that isn't there when parsing the
    /// same diff without the trailing newline.
    func testTrailingNewlineDoesNotProduceAPhantomContextLine() {
        let withoutTrailingNewline = DiffParser.parse(Fixtures.simpleModify)
        let withTrailingNewline = DiffParser.parse(Fixtures.simpleModify + "\n")
        XCTAssertEqual(withTrailingNewline, withoutTrailingNewline)
        XCTAssertEqual(withTrailingNewline[0].hunks[0].lines.count, 4)
    }

    /// A hunk header whose range is empty after the sign used to trap on
    /// `[0]` of an empty split, crashing the whole app on one bad line.
    func testMalformedHunkHeaderDoesNotTrap() {
        XCTAssertEqual(DiffParser.hunkStart("-"), 0)
        XCTAssertEqual(DiffParser.hunkStart("-,"), 0)
        XCTAssertEqual(DiffParser.hunkStart("+"), 0)
        XCTAssertEqual(DiffParser.hunkStart("-12,7"), 12)
        XCTAssertEqual(DiffParser.hunkStart("+12"), 12)
        XCTAssertEqual(DiffParser.hunkStart("-0,0"), 0)

        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ - +1 @@
        +hello
        """
        let files = DiffParser.parse(patch)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.hunks.first?.lines.count, 1)
    }

}
