import XCTest
@testable import DifftServices

final class EvidenceWatcherTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testCurrentPNGsSortedAndFiltered() throws {
        try Data().write(to: dir.appendingPathComponent("b.png"))
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        XCTAssertEqual(EvidenceWatcher.currentPNGs(in: dir).map(\.lastPathComponent), ["a.png", "b.png"])
    }

    func testMissingDirEmpty() {
        XCTAssertEqual(EvidenceWatcher.currentPNGs(in: dir.appendingPathComponent("nope")), [])
    }

    func testVerdictParsing() throws {
        try Data(#"{"verdict": "pass", "summary": "Looks right"}"#.utf8)
            .write(to: dir.appendingPathComponent("verdict.json"))
        let v = EvidenceWatcher.verdict(in: dir)
        XCTAssertEqual(v?.verdict, "pass")
        XCTAssertEqual(v?.summary, "Looks right")
    }

    func testVerdictNilWhenMissingOrBroken() throws {
        XCTAssertNil(EvidenceWatcher.verdict(in: dir))
        try Data("broken".utf8).write(to: dir.appendingPathComponent("verdict.json"))
        XCTAssertNil(EvidenceWatcher.verdict(in: dir))
    }
}
