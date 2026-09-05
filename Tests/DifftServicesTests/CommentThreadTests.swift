import XCTest
@testable import DifftServices

final class CommentThreadTests: XCTestCase {
    private func comment(_ id: Int, path: String = "a.swift", line: Int? = 10,
                         replyTo: Int? = nil, at: String = "2026-01-01T00:00:00Z",
                         author: String = "alice", resolved: Bool = false) -> ReviewComment {
        ReviewComment(id: id, author: author, body: "body \(id)", path: path, line: line,
                      side: "RIGHT", createdAt: at, inReplyToID: replyTo, resolved: resolved)
    }

    func testGroupsRepliesUnderTheirRoot() {
        let threads = CommentThread.group([
            comment(1, at: "2026-01-01T00:00:00Z"),
            comment(2, replyTo: 1, at: "2026-01-01T01:00:00Z"),
            comment(3, replyTo: 1, at: "2026-01-01T02:00:00Z"),
        ])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].root.id, 1)
        XCTAssertEqual(threads[0].replies.map(\.id), [2, 3])
        XCTAssertEqual(threads[0].comments.count, 3)
    }

    func testSeparateRootsStaySeparateThreads() {
        let threads = CommentThread.group([
            comment(1, line: 10),
            comment(2, line: 20),
        ])
        XCTAssertEqual(threads.map(\.id), [1, 2])
    }

    func testRepliesSortByCreationNotInputOrder() {
        let threads = CommentThread.group([
            comment(3, replyTo: 1, at: "2026-01-01T03:00:00Z"),
            comment(1, at: "2026-01-01T00:00:00Z"),
            comment(2, replyTo: 1, at: "2026-01-01T01:00:00Z"),
        ])
        XCTAssertEqual(threads[0].replies.map(\.id), [2, 3])
    }

    /// A reply chained off another reply still belongs to the thread root.
    func testTransitiveReplyChainCollapsesToOneThread() {
        let threads = CommentThread.group([
            comment(1),
            comment(2, replyTo: 1),
            comment(3, replyTo: 2),
        ])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].root.id, 1)
        XCTAssertEqual(threads[0].replies.map(\.id), [2, 3])
    }

    /// Losing a reviewer's comment because its parent is missing would be
    /// worse than showing it unattached.
    func testOrphanReplyBecomesItsOwnThread() {
        let threads = CommentThread.group([comment(2, replyTo: 999)])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].root.id, 2)
        XCTAssertTrue(threads[0].replies.isEmpty)
    }

    /// Malformed data must not hang the grouping walk.
    func testCyclicReplyChainTerminates() {
        let threads = CommentThread.group([
            comment(1, replyTo: 2),
            comment(2, replyTo: 1),
        ])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].comments.count, 2)
    }

    func testSortsByPathThenLine() {
        let threads = CommentThread.group([
            comment(1, path: "b.swift", line: 5),
            comment(2, path: "a.swift", line: 30),
            comment(3, path: "a.swift", line: 2),
        ])
        XCTAssertEqual(threads.map(\.id), [3, 2, 1])
    }

    /// Outdated comments (GitHub drops the line anchor) belong at the end of
    /// their file's group, not sorted as if they were at line 0.
    func testOutdatedThreadsSortAfterAnchoredOnes() {
        let threads = CommentThread.group([
            comment(1, path: "a.swift", line: nil),
            comment(2, path: "a.swift", line: 40),
        ])
        XCTAssertEqual(threads.map(\.id), [2, 1])
        XCTAssertTrue(threads[1].isOutdated)
    }

    func testParticipantsAreUniqueInSpeakingOrder() {
        let threads = CommentThread.group([
            comment(1, at: "2026-01-01T00:00:00Z", author: "alice"),
            comment(2, replyTo: 1, at: "2026-01-01T01:00:00Z", author: "bob"),
            comment(3, replyTo: 1, at: "2026-01-01T02:00:00Z", author: "alice"),
        ])
        XCTAssertEqual(threads[0].participants, ["alice", "bob"])
    }

    func testLastActivityIsNewestComment() {
        let threads = CommentThread.group([
            comment(1, at: "2026-01-01T00:00:00Z"),
            comment(2, replyTo: 1, at: "2026-03-05T09:00:00Z"),
        ])
        XCTAssertEqual(threads[0].lastActivityAt, "2026-03-05T09:00:00Z")
    }

    func testResolvedFlagComesFromRoot() {
        let threads = CommentThread.group([comment(1, resolved: true)])
        XCTAssertTrue(threads[0].resolved)
    }

    func testEmptyInputProducesNoThreads() {
        XCTAssertTrue(CommentThread.group([]).isEmpty)
    }
}
