import XCTest
@testable import DifftServices

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    var responses: [ProcessResult] = []
    var calls: [(executable: String, arguments: [String])] = []
    func run(_ executable: String, arguments: [String], currentDirectory: URL?) async throws -> ProcessResult {
        calls.append((executable, arguments))
        return responses.isEmpty ? ProcessResult(stdout: "", stderr: "", exitCode: 0) : responses.removeFirst()
    }
}

final class GitHubServiceTests: XCTestCase {
    func testListPRsParsesGhJSON() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: """
        [{"number": 12, "title": "Fix bug", "body": "Fixes crash", "headRefName": "fix/crash", "author": {"login": "alice"}}]
        """, stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        let prs = try await svc.listPRs(repoDir: URL(fileURLWithPath: "/tmp/repo"))
        XCTAssertEqual(prs, [PullRequest(number: 12, title: "Fix bug", body: "Fixes crash", headRefName: "fix/crash", authorLogin: "alice")])
        XCTAssertEqual(fake.calls[0].executable, "gh")
        XCTAssertEqual(fake.calls[0].arguments, ["pr", "list", "--json", "number,title,body,headRefName,baseRefName,author", "--limit", "50"])
    }

    func testFetchDiffParsesIntoFileDiffs() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -x
        +y
        """, stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        let files = try await svc.fetchDiff(repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 12)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "a.txt")
        XCTAssertEqual(fake.calls[0].arguments, ["pr", "diff", "12"])
    }

    func testFetchCommentsParsesAndSorts() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: """
        [{"id": 2, "user": {"login": "bob"}, "body": "reply", "path": "a.py",
          "line": 10, "side": "RIGHT", "created_at": "2026-08-02T00:00:00Z", "in_reply_to_id": 1},
         {"id": 1, "user": {"login": "alice"}, "body": "first", "path": "a.py",
          "line": 10, "side": "RIGHT", "created_at": "2026-08-01T00:00:00Z", "in_reply_to_id": null}]
        """, stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        let comments = try await svc.fetchComments(repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7)
        XCTAssertEqual(fake.calls[0].arguments, ["api", "repos/{owner}/{repo}/pulls/7/comments", "--paginate"])
        XCTAssertEqual(comments.map(\.id), [1, 2])  // sorted by createdAt
        XCTAssertEqual(comments[0].author, "alice")
        XCTAssertEqual(comments[1].inReplyToID, 1)
        XCTAssertEqual(comments[0].line, 10)
    }

    func testCommentBodySegments() {
        let body = """
        Intro **bold**

        ```python
        def x():
            return 1
        ```
        Outro
        """
        let segs = CommentBodySegment.parse(body)
        XCTAssertEqual(segs, [
            .text("Intro **bold**"),
            .code("def x():\n    return 1"),
            .text("Outro"),
        ])
        XCTAssertEqual(CommentBodySegment.parse("plain only"), [.text("plain only")])
        // unterminated fence keeps the code
        XCTAssertEqual(CommentBodySegment.parse("a\n```\ncode"), [.text("a"), .code("code")])
    }

    func testReplyAndResolveArgs() async throws {
        let fake = FakeProcessRunner()
        let svc = GitHubService(runner: fake)
        try await svc.replyToComment(repoDir: URL(fileURLWithPath: "/tmp/r"), number: 9, commentID: 123, body: "hi there")
        XCTAssertEqual(fake.calls[0].arguments, [
            "api", "-X", "POST", "repos/{owner}/{repo}/pulls/9/comments/123/replies", "-f", "body=hi there",
        ])
        try await svc.resolveThread(repoDir: URL(fileURLWithPath: "/tmp/r"), threadID: "T_abc")
        XCTAssertTrue(fake.calls[1].arguments.contains("id=T_abc"))
        XCTAssertTrue(fake.calls[1].arguments.joined().contains("resolveReviewThread"))
    }

    func testNonZeroExitThrows() async {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "", stderr: "no auth", exitCode: 1)]
        let svc = GitHubService(runner: fake)
        do {
            _ = try await svc.listPRs(repoDir: URL(fileURLWithPath: "/tmp"))
            XCTFail("expected throw")
        } catch let e as GitHubServiceError {
            XCTAssertEqual(e, .commandFailed("no auth"))
        } catch { XCTFail("wrong error") }
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let runner = DefaultProcessRunner()
        let result = try await runner.run("sh", arguments: ["-c", "yes | head -c 200000"], currentDirectory: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stdout.count, 128000)
    }
}
