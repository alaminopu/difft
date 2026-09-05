import XCTest
@testable import DifftServices

final class WorktreeManagerTests: XCTestCase {
    var base: URL!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func testWorktreeURLNaming() {
        let mgr = WorktreeManager(runner: FakeProcessRunner(), baseDir: base)
        XCTAssertEqual(mgr.worktreeURL(repoName: "myrepo", prNumber: 4).lastPathComponent, "myrepo-pr4")
    }

    func testEnsureWorktreeRunsCheckoutAndWorktreeAdd() async throws {
        let fake = FakeProcessRunner()
        let mgr = WorktreeManager(runner: fake, baseDir: base)
        let clone = URL(fileURLWithPath: "/tmp/clone")
        _ = try await mgr.ensureWorktree(cloneDir: clone, repoName: "myrepo", prNumber: 4)
        XCTAssertEqual(fake.calls.count, 3)
        XCTAssertEqual(fake.calls[0].executable, "git")
        XCTAssertEqual(fake.calls[0].arguments, ["worktree", "prune"])
        XCTAssertEqual(fake.calls[1].executable, "git")
        XCTAssertEqual(fake.calls[1].arguments, ["fetch", "origin", "+pull/4/head:difft-pr-4"])
        XCTAssertEqual(fake.calls[2].executable, "git")
        XCTAssertEqual(fake.calls[2].arguments,
                       ["worktree", "add", mgr.worktreeURL(repoName: "myrepo", prNumber: 4).path, "difft-pr-4"])
    }

    func testEnsureWorktreeSkipsWhenDirExists() async throws {
        let fake = FakeProcessRunner()
        let mgr = WorktreeManager(runner: fake, baseDir: base)
        try FileManager.default.createDirectory(at: mgr.worktreeURL(repoName: "r", prNumber: 1), withIntermediateDirectories: true)
        _ = try await mgr.ensureWorktree(cloneDir: URL(fileURLWithPath: "/tmp"), repoName: "r", prNumber: 1)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testEnsureWorktreeReusePathBumpsMtime() async throws {
        let fake = FakeProcessRunner()
        let mgr = WorktreeManager(runner: fake, baseDir: base)
        let target = mgr.worktreeURL(repoName: "r", prNumber: 1)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let oldDate = Date().addingTimeInterval(-10 * 86400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: target.path)
        _ = try await mgr.ensureWorktree(cloneDir: URL(fileURLWithPath: "/tmp"), repoName: "r", prNumber: 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let newDate = attrs[.modificationDate] as? Date
        XCTAssertNotNil(newDate)
        XCTAssertGreaterThan(newDate ?? Date.distantPast, oldDate)
    }

    func testEnsureWorktreeThrowsOnFailure() async {
        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "", stderr: "bad pr", exitCode: 1)]
        let mgr = WorktreeManager(runner: fake, baseDir: base)
        do {
            _ = try await mgr.ensureWorktree(cloneDir: URL(fileURLWithPath: "/tmp"), repoName: "r", prNumber: 9)
            XCTFail("expected throw")
        } catch let e as WorktreeError {
            XCTAssertEqual(e, .commandFailed("bad pr"))
        } catch { XCTFail("wrong error") }
    }

    func testPruneRemovesOldDirs() throws {
        let mgr = WorktreeManager(runner: FakeProcessRunner(), baseDir: base)
        let old = base.appendingPathComponent("old-pr1")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: old.path)
        let fresh = base.appendingPathComponent("fresh-pr2")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try mgr.prune(olderThan: 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testRefreshWorktreeFetchesResetsAndReturnsHead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = dir.appendingPathComponent("repo-pr9")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = FakeProcessRunner()
        fake.responses = [
            ProcessResult(stdout: "", stderr: "", exitCode: 0),            // fetch
            ProcessResult(stdout: "", stderr: "", exitCode: 0),            // reset --hard
            ProcessResult(stdout: "abc1234def\n", stderr: "", exitCode: 0), // rev-parse
        ]
        let mgr = WorktreeManager(runner: fake, baseDir: dir)
        let head = try await mgr.refreshWorktree(
            cloneDir: URL(fileURLWithPath: "/tmp/clone"), repoName: "repo", prNumber: 9)

        XCTAssertEqual(head, "abc1234def")
        // Existing worktree: no prune/add, straight to fetch + reset + rev-parse.
        // Fetch runs in the worktree with no destination branch (git refuses
        // to fetch into a checked-out branch), then reset moves it.
        XCTAssertEqual(fake.calls.map(\.arguments), [
            ["fetch", "origin", "pull/9/head"],
            ["reset", "--hard", "FETCH_HEAD"],
            ["rev-parse", "HEAD"],
        ])
    }

    func testRefreshWorktreeThrowsWhenFetchFails() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = dir.appendingPathComponent("repo-pr9")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "", stderr: "no such ref", exitCode: 1)]
        let mgr = WorktreeManager(runner: fake, baseDir: dir)
        do {
            _ = try await mgr.refreshWorktree(
                cloneDir: URL(fileURLWithPath: "/tmp/clone"), repoName: "repo", prNumber: 9)
            XCTFail("expected throw")
        } catch let e as WorktreeError {
            XCTAssertEqual(e, .commandFailed("no such ref"))
        } catch { XCTFail("wrong error") }
    }
}
