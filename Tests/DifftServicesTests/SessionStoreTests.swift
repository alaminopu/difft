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

    /// Sessions written before the Explain pane existed have no `explanation`
    /// key. They must still load, or upgrading silently loses every PR's
    /// viewed-file and chat state.
    func testLoadsASessionWrittenBeforeExplanationExisted() throws {
        let legacy = """
        {"pr":{"number":1166,"title":"Prepare Air 0.49.0","body":"B",
        "headRefName":"agent/release-0.49.0","authorLogin":"a"},
        "repoDir":"/tmp/repo","viewedFiles":["a.txt"],
        "chat":[{"role":"user","text":"why?"}],"findings":[]}
        """
        let data = Data(legacy.utf8)
        let decoded = try JSONDecoder().decode(SessionData.self, from: data)
        XCTAssertEqual(decoded.pr.number, 1166)
        XCTAssertEqual(decoded.viewedFiles, ["a.txt"])
        XCTAssertEqual(decoded.chat.count, 1)
        XCTAssertNil(decoded.explanation)
    }

    /// A review written over an afternoon has to survive closing the PR, and
    /// the app quitting.
    func testDraftReviewSurvivesARoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var data = SessionData(pr: PullRequest(number: 3, title: "t", body: "", headRefName: "h",
                                               authorLogin: "a"),
                               repoDir: "/tmp/repo", viewedFiles: [], chat: [], findings: [])
        data.draftComments = [DraftComment(path: "a.swift", line: 9, startLine: 7, body: "note")]
        data.draftReviewBody = "summary"
        try store.save(data)

        let back = try XCTUnwrap(store.load(repo: "repo", prNumber: 3))
        XCTAssertEqual(back.draftComments.count, 1)
        XCTAssertEqual(back.draftComments[0].path, "a.swift")
        XCTAssertEqual(back.draftComments[0].startLine, 7)
        XCTAssertEqual(back.draftReviewBody, "summary")
    }

    /// Sessions written before drafts existed are already on disk.
    func testSessionsWithoutDraftsStillDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"pr": {"number": 4, "title": "t", "body": "", "headRefName": "h", "authorLogin": "a"},
         "repoDir": "/tmp/repo", "viewedFiles": [], "chat": [], "findings": []}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("repo-pr4.json"))
        let back = try XCTUnwrap(SessionStore(directory: dir).load(repo: "repo", prNumber: 4))
        XCTAssertTrue(back.draftComments.isEmpty)
        XCTAssertEqual(back.draftReviewBody, "")
    }

}
