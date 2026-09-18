import XCTest
@testable import DifftServices

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    var responses: [ProcessResult] = []
    var calls: [(executable: String, arguments: [String])] = []
    /// What was piped to stdin, for the calls that use `gh api --input -`.
    var stdinPayloads: [Data] = []
    func run(_ executable: String, arguments: [String], currentDirectory: URL?) async throws -> ProcessResult {
        calls.append((executable, arguments))
        return responses.isEmpty ? ProcessResult(stdout: "", stderr: "", exitCode: 0) : responses.removeFirst()
    }
    func run(_ executable: String, arguments: [String], currentDirectory: URL?,
             stdin: Data?) async throws -> ProcessResult {
        if let stdin { stdinPayloads.append(stdin) }
        return try await run(executable, arguments: arguments, currentDirectory: currentDirectory)
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
        XCTAssertEqual(fake.calls[0].arguments,
                       ["pr", "list", "--state", "open", "--limit", "100",
                        "--json", GitHubService.prFields])
    }

    /// Filtering a fetched page only ever searches that page. On a repository
    /// with hundreds of PRs the query has to reach GitHub.
    func testSearchAndScopeAreSentToGitHub() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "[]", stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        _ = try await svc.listPRs(repoDir: URL(fileURLWithPath: "/tmp/repo"),
                                  scope: .merged, search: "  author:alice  ")
        let args = fake.calls[0].arguments
        XCTAssertEqual(Array(args[0..<4]), ["pr", "list", "--state", "merged"])
        // Trimmed, so trailing whitespace from the search field is not a term.
        XCTAssertEqual(args.last, "author:alice")
        XCTAssertEqual(args[args.count - 2], "--search")
    }

    func testNoSearchFlagWhenTheQueryIsEmpty() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "[]", stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        _ = try await svc.listPRs(repoDir: URL(fileURLWithPath: "/tmp/repo"), search: "   ")
        XCTAssertFalse(fake.calls[0].arguments.contains("--search"))
    }

    /// A PR reached by number is usually one that has already been merged, so
    /// the state has to come back with it.
    func testFetchPRByNumberCarriesState() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: """
        {"number": 6022, "title": "Old work", "body": "", "headRefName": "x",
         "baseRefName": "main", "author": {"login": "alice"},
         "state": "MERGED", "isDraft": false, "createdAt": "2026-01-02T03:04:05Z"}
        """, stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        let pr = try await svc.fetchPR(repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 6022)
        XCTAssertEqual(pr.number, 6022)
        XCTAssertEqual(pr.stateLabel, "MERGED")
        XCTAssertFalse(pr.isOpen)
        XCTAssertEqual(Array(fake.calls[0].arguments[0..<3]), ["pr", "view", "6022"])
    }

    /// An account deleted since it opened the PR decodes to no login rather
    /// than failing the whole list.
    func testMissingAuthorDoesNotFailTheList() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: """
        [{"number": 1, "title": "t", "body": "", "headRefName": "h", "author": null}]
        """, stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        let prs = try await svc.listPRs(repoDir: URL(fileURLWithPath: "/tmp/repo"))
        XCTAssertEqual(prs.first?.authorLogin, "")
        // No state field at all still reads as open.
        XCTAssertTrue(prs.first?.isOpen ?? false)
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

    func testFetchCommitsParsesGhJSON() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: """
        {"commits": [
          {"oid": "abc1234567890", "messageHeadline": "Fix the thing", "messageBody": "Longer\\nexplanation",
           "authoredDate": "2026-03-01T10:00:00Z", "authors": [{"login": "alice", "name": "Alice A"}]}
        ]}
        """, stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        let commits = try await svc.fetchCommits(repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].sha, "abc1234567890")
        XCTAssertEqual(commits[0].shortSHA, "abc1234")
        XCTAssertEqual(commits[0].subject, "Fix the thing")
        XCTAssertEqual(commits[0].author, "alice")
        XCTAssertTrue(commits[0].hasBody)
        XCTAssertEqual(fake.calls[0].arguments, ["pr", "view", "7", "--json", "commits"])
    }

    /// A commit authored outside GitHub carries only a git name, no login.
    func testFetchCommitsFallsBackToAuthorName() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: """
        {"commits": [
          {"oid": "deadbeef", "messageHeadline": "Vendored change", "messageBody": "",
           "authoredDate": "2026-03-01T10:00:00Z", "authors": [{"login": null, "name": "Offline Contributor"}]}
        ]}
        """, stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        let commits = try await svc.fetchCommits(repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7)
        XCTAssertEqual(commits[0].author, "Offline Contributor")
        XCTAssertFalse(commits[0].hasBody)
    }

    /// A PR whose commits list came back empty must not throw.
    func testFetchCommitsHandlesNoAuthorsAndEmptyList() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: #"{"commits": []}"#, stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        let commits = try await svc.fetchCommits(repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7)
        XCTAssertTrue(commits.isEmpty)
    }

    func testFetchCommitsThrowsOnFailure() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "", stderr: "no such PR", exitCode: 1)]
        let svc = GitHubService(runner: fake)
        do {
            _ = try await svc.fetchCommits(repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? GitHubServiceError, .commandFailed("no such PR"))
        }
    }

}

extension GitHubServiceTests {
    func testUpdateCommentPatchesTheComment() async throws {
        let fake = FakeProcessRunner()
        let svc = GitHubService(runner: fake)
        try await svc.updateComment(repoDir: URL(fileURLWithPath: "/tmp/r"), commentID: 99, body: "revised")
        XCTAssertEqual(fake.calls[0].arguments, [
            "api", "-X", "PATCH", "repos/{owner}/{repo}/pulls/comments/99", "-f", "body=revised",
        ])
    }

    func testCreateCommentOnASingleLineOmitsStartLine() async throws {
        let fake = FakeProcessRunner()
        let svc = GitHubService(runner: fake)
        try await svc.createComment(repoDir: URL(fileURLWithPath: "/tmp/r"), number: 7,
                                    commitID: "abc123", path: "a/b.py",
                                    line: 42, startLine: nil, body: "hi")
        let args = fake.calls[0].arguments
        XCTAssertTrue(args.contains("line=42"))
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("start_line=") }),
                       "a single-line comment must not send start_line")
    }

    /// GitHub rejects start_line when it equals line, so a one-line selection
    /// has to degrade to a plain line comment.
    func testCreateCommentCollapsesAOneLineRange() async throws {
        let fake = FakeProcessRunner()
        let svc = GitHubService(runner: fake)
        try await svc.createComment(repoDir: URL(fileURLWithPath: "/tmp/r"), number: 7,
                                    commitID: "abc123", path: "a/b.py",
                                    line: 42, startLine: 42, body: "hi")
        XCTAssertFalse(fake.calls[0].arguments.contains(where: { $0.hasPrefix("start_line=") }))
    }

    func testCreateCommentOnARangeSendsBothBounds() async throws {
        let fake = FakeProcessRunner()
        let svc = GitHubService(runner: fake)
        try await svc.createComment(repoDir: URL(fileURLWithPath: "/tmp/r"), number: 7,
                                    commitID: "abc123", path: "a/b.py",
                                    line: 50, startLine: 42, body: "hi")
        let args = fake.calls[0].arguments
        XCTAssertTrue(args.contains("line=50"))
        XCTAssertTrue(args.contains("start_line=42"))
        XCTAssertTrue(args.contains("side=RIGHT"))
        XCTAssertTrue(args.contains("start_side=RIGHT"))
    }

    func testCreateCommentThrowsOnFailure() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "", stderr: "line must be part of the diff", exitCode: 1)]
        let svc = GitHubService(runner: fake)
        do {
            try await svc.createComment(repoDir: URL(fileURLWithPath: "/tmp/r"), number: 7,
                                        commitID: "abc", path: "a.py", line: 1, startLine: nil, body: "x")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? GitHubServiceError, .commandFailed("line must be part of the diff"))
        }
    }

    func testCurrentUserReadsTheLogin() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "alamin-br\n", stderr: "", exitCode: 0)]
        let svc = GitHubService(runner: fake)
        let login = try await svc.currentUser(repoDir: URL(fileURLWithPath: "/tmp/r"))
        XCTAssertEqual(login, "alamin-br")
        XCTAssertEqual(fake.calls[0].arguments, ["api", "user", "--jq", ".login"])
    }
    /// Draft is not one of GitHub's states — it is a flag on an open PR — so
    /// the draft scopes list open PRs and narrow with a search qualifier.
    func testDraftScopesListOpenPRsWithAQualifier() async throws {
        for (scope, qualifier) in [(PRScope.draft, "is:draft"), (PRScope.ready, "-is:draft")] {
            let fake = FakeProcessRunner()
            fake.responses = [ProcessResult(stdout: "[]", stderr: "", exitCode: 0)]
            _ = try await GitHubService(runner: fake).listPRs(
                repoDir: URL(fileURLWithPath: "/tmp/repo"), scope: scope)
            let args = fake.calls[0].arguments
            XCTAssertEqual(Array(args[0..<4]), ["pr", "list", "--state", "open"])
            XCTAssertEqual(args.last, qualifier)
            XCTAssertEqual(args[args.count - 2], "--search")
        }
    }

    /// The qualifier has to survive alongside what the user typed, not
    /// replace it.
    func testDraftQualifierCombinesWithTheUserSearch() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "[]", stderr: "", exitCode: 0)]
        _ = try await GitHubService(runner: fake).listPRs(
            repoDir: URL(fileURLWithPath: "/tmp/repo"), scope: .draft, search: "author:alice")
        XCTAssertEqual(fake.calls[0].arguments.last, "author:alice is:draft")
    }

    /// "Open" keeps covering drafts, the way GitHub's own Open tab does.
    func testOpenScopeAddsNoQualifier() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "[]", stderr: "", exitCode: 0)]
        _ = try await GitHubService(runner: fake).listPRs(
            repoDir: URL(fileURLWithPath: "/tmp/repo"), scope: .open)
        XCTAssertFalse(fake.calls[0].arguments.contains("--search"))
    }

    /// Opening a PR compares the checkout against this to decide whether it
    /// needs the network at all, so it has to come back with the list.
    func testListCarriesTheHeadCommit() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: """
        [{"number": 1, "title": "t", "body": "", "headRefName": "h",
          "baseRefName": "main", "baseRefOid": "aaa", "headRefOid": "bbb",
          "author": {"login": "alice"}}]
        """, stderr: "", exitCode: 0)]
        let prs = try await GitHubService(runner: fake).listPRs(repoDir: URL(fileURLWithPath: "/tmp/repo"))
        XCTAssertEqual(prs.first?.headRefOid, "bbb")
        XCTAssertEqual(prs.first?.baseRefOid, "aaa")
        XCTAssertTrue(GitHubService.prFields.contains("headRefOid"))
    }

    // MARK: - Reviews

    func testFetchReviewsMapsVerdicts() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: """
        [{"id": 1, "user": {"login": "alice"}, "state": "APPROVED", "body": "ship it",
          "submitted_at": "2026-09-15T13:40:35Z"},
         {"id": 2, "user": {"login": "bob"}, "state": "CHANGES_REQUESTED", "body": "no",
          "submitted_at": "2026-09-16T13:40:35Z"}]
        """, stderr: "", exitCode: 0)]
        let reviews = try await GitHubService(runner: fake)
            .fetchReviews(repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7)
        XCTAssertEqual(reviews.count, 2)
        XCTAssertTrue(reviews[0].isApproval)
        XCTAssertEqual(reviews[0].label, "approved")
        XCTAssertTrue(reviews[1].isBlocking)
        XCTAssertEqual(reviews[1].label, "requested changes")
    }

    /// GitHub wraps inline notes in an empty COMMENTED review. Those carry no
    /// verdict and no text, so showing them would be a row saying nothing.
    func testAnEmptyCommentedReviewIsNotMeaningful() {
        let envelope = PullRequestReview(id: 1, author: "a", state: "COMMENTED",
                                         body: "  \n ", submittedAt: nil)
        XCTAssertFalse(envelope.isMeaningful)
        XCTAssertTrue(PullRequestReview(id: 2, author: "a", state: "COMMENTED",
                                        body: "a real note", submittedAt: nil).isMeaningful)
        // A verdict is meaningful even with no words attached.
        XCTAssertTrue(PullRequestReview(id: 3, author: "a", state: "APPROVED",
                                        body: "", submittedAt: nil).isMeaningful)
    }

    /// A deleted account has no login, and one odd field must not cost the
    /// whole list.
    func testReviewsSurviveAMissingAuthorAndState() async throws {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(
            stdout: #"[{"id": 9, "user": null, "body": null, "submitted_at": null}]"#,
            stderr: "", exitCode: 0)]
        let reviews = try await GitHubService(runner: fake)
            .fetchReviews(repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7)
        XCTAssertEqual(reviews.first?.author, "")
        XCTAssertEqual(reviews.first?.state, "COMMENTED")
    }

    func testSubmitReviewSendsOneRequestWithEveryNote() async throws {
        let fake = FakeProcessRunner()
        let drafts = [
            DraftComment(path: "a.swift", line: 12, body: "first"),
            DraftComment(path: "b.swift", line: 40, startLine: 36, body: "second"),
        ]
        try await GitHubService(runner: fake).submitReview(
            repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7, commitID: "deadbeef",
            verdict: .requestChanges, body: "  needs work  ", comments: drafts)

        // One call, not one per note.
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].arguments,
                       ["api", "-X", "POST", "repos/{owner}/{repo}/pulls/7/reviews", "--input", "-"])

        let payload = try XCTUnwrap(fake.stdinPayloads.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["event"] as? String, "REQUEST_CHANGES")
        XCTAssertEqual(json["commit_id"] as? String, "deadbeef")
        XCTAssertEqual(json["body"] as? String, "needs work")

        let comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.count, 2)
        XCTAssertEqual(comments[0]["path"] as? String, "a.swift")
        XCTAssertEqual(comments[0]["line"] as? Int, 12)
        // GitHub rejects start_line when it equals line, so a single-line note
        // must not carry one.
        XCTAssertNil(comments[0]["start_line"])
        XCTAssertEqual(comments[1]["start_line"] as? Int, 36)
        XCTAssertEqual(comments[1]["start_side"] as? String, "RIGHT")
    }

    /// An empty summary is omitted rather than sent as "", which GitHub shows
    /// as a blank review body.
    func testSubmitReviewOmitsAnEmptyBody() async throws {
        let fake = FakeProcessRunner()
        try await GitHubService(runner: fake).submitReview(
            repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7, commitID: "abc",
            verdict: .approve, body: "   ", comments: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(fake.stdinPayloads.first)) as? [String: Any])
        XCTAssertNil(json["body"])
        XCTAssertEqual(json["event"] as? String, "APPROVE")
    }

    func testSubmitReviewThrowsWhatGitHubSaid() async {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(
            stdout: "", stderr: "gh: Pull request review thread line must be part of the diff",
            exitCode: 1)]
        do {
            try await GitHubService(runner: fake).submitReview(
                repoDir: URL(fileURLWithPath: "/tmp/repo"), number: 7, commitID: "abc",
                verdict: .comment, body: "x", comments: [])
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("must be part of the diff"),
                          error.localizedDescription)
        }
    }

    private func review(_ author: String, _ state: String) -> PullRequestReview {
        PullRequestReview(id: Int.random(in: 1...9_999_999), author: author,
                          state: state, body: "", submittedAt: nil)
    }

    /// The case that produced a wrong answer on a real pull request: a
    /// reviewer requested changes and later approved, and counting every
    /// review ever submitted reported the PR as blocked.
    func testTheLatestVerdictPerReviewerWins() {
        let tally = ReviewTally.of([
            review("bram", "CHANGES_REQUESTED"),
            review("bram", "COMMENTED"),
            review("bram", "APPROVED"),
        ])
        XCTAssertEqual(tally, ReviewTally(approvals: 1, blocking: 0))
    }

    /// A plain comment says nothing about whether the PR can merge.
    func testACommentDoesNotChangeStanding() {
        XCTAssertEqual(ReviewTally.of([review("a", "COMMENTED")]),
                       ReviewTally(approvals: 0, blocking: 0))
        XCTAssertEqual(ReviewTally.of([review("a", "APPROVED"), review("a", "COMMENTED")]),
                       ReviewTally(approvals: 1, blocking: 0))
    }

    /// Dismissing a review removes that reviewer's standing — that is what it
    /// is for.
    func testDismissalClearsAVerdict() {
        XCTAssertEqual(
            ReviewTally.of([review("a", "CHANGES_REQUESTED"), review("a", "DISMISSED")]),
            ReviewTally(approvals: 0, blocking: 0))
    }

    func testReviewersAreCountedIndependently() {
        let tally = ReviewTally.of([
            review("a", "APPROVED"),
            review("b", "CHANGES_REQUESTED"),
            review("c", "APPROVED"),
            review("b", "CHANGES_REQUESTED"),
        ])
        XCTAssertEqual(tally, ReviewTally(approvals: 2, blocking: 1))
    }

    func testNoReviews() {
        XCTAssertEqual(ReviewTally.of([]), ReviewTally())
    }

}
