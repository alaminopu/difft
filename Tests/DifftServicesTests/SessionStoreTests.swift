import XCTest
@testable import DifftServices

final class SessionStoreTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func sample() -> SessionData {
        SessionData(
            pr: PullRequest(number: 7, title: "T", body: "B", headRefName: "h", authorLogin: "a"),
            repoDir: "/tmp/repo", viewedFiles: ["a.txt"],
            chat: [ChatMessage(role: "user", text: "why?", contextChip: "a.txt:1-3")],
            findings: [Finding(severity: "high", file: "a.txt", line: 3, explanation: "bad")])
    }

    func testRoundTrip() throws {
        let store = SessionStore(directory: dir)
        try store.save(sample())
        let loaded = store.load(repo: "repo", prNumber: 7)
        XCTAssertEqual(loaded, sample())
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(SessionStore(directory: dir).load(repo: "nope", prNumber: 1))
    }

    func testCorruptFileRenamedToBak() throws {
        let store = SessionStore(directory: dir)
        let file = dir.appendingPathComponent(SessionStore.key(repo: "repo", prNumber: 7) + ".json")
        try Data("{{{not json".utf8).write(to: file)
        XCTAssertNil(store.load(repo: "repo", prNumber: 7))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".bak"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
