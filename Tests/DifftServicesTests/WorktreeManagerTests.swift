import XCTest
@testable import DifftServices

final class WorktreeManagerTests: XCTestCase {
    var base: URL!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    /// A manager whose private clone of `repoName` already exists, so the
    /// calls under test are the worktree's own.
    private func manager(_ runner: ProcessRunning, baseDir: URL, repoName: String) -> WorktreeManager {
        let repos = baseDir.appendingPathComponent("repos")
        try? FileManager.default.createDirectory(at: repos.appendingPathComponent("\(repoName).git"),
                                                 withIntermediateDirectories: true)
        return WorktreeManager(runner: runner, baseDir: baseDir, reposDir: repos)
    }

    func testWorktreeURLNaming() {
        let mgr = WorktreeManager(runner: FakeProcessRunner(), baseDir: base, reposDir: base.appendingPathComponent("repos"))
        XCTAssertEqual(mgr.worktreeURL(repoName: "myrepo", prNumber: 4).lastPathComponent, "myrepo-pr4")
    }

    func testEnsureWorktreeRunsCheckoutAndWorktreeAdd() async throws {
        let fake = FakeProcessRunner()
        let mgr = manager(fake, baseDir: base, repoName: "myrepo")
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
        let mgr = manager(fake, baseDir: base, repoName: "r")
        try FileManager.default.createDirectory(at: mgr.worktreeURL(repoName: "r", prNumber: 1), withIntermediateDirectories: true)
        _ = try await mgr.ensureWorktree(cloneDir: URL(fileURLWithPath: "/tmp"), repoName: "r", prNumber: 1)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testEnsureWorktreeReusePathBumpsMtime() async throws {
        let fake = FakeProcessRunner()
        let mgr = manager(fake, baseDir: base, repoName: "r")
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
        let mgr = manager(fake, baseDir: base, repoName: "r")
        do {
            _ = try await mgr.ensureWorktree(cloneDir: URL(fileURLWithPath: "/tmp"), repoName: "r", prNumber: 9)
            XCTFail("expected throw")
        } catch let e as WorktreeError {
            XCTAssertEqual(e, .commandFailed("bad pr"))
        } catch { XCTFail("wrong error") }
    }

    func testPruneRemovesOldDirs() throws {
        let mgr = WorktreeManager(runner: FakeProcessRunner(), baseDir: base, reposDir: base.appendingPathComponent("repos"))
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
            ProcessResult(stdout: "", stderr: "", exitCode: 0),             // fetch
            ProcessResult(stdout: "abc1234def\n", stderr: "", exitCode: 0),  // rev-parse FETCH_HEAD
            ProcessResult(stdout: "0000000000\n", stderr: "", exitCode: 0),  // rev-parse HEAD
            ProcessResult(stdout: "", stderr: "", exitCode: 0),             // status: clean
            ProcessResult(stdout: "", stderr: "", exitCode: 0),             // reset --hard
            ProcessResult(stdout: "abc1234def\n", stderr: "", exitCode: 0),  // rev-parse HEAD
        ]
        let mgr = manager(fake, baseDir: dir, repoName: "repo")
        let head = try await mgr.refreshWorktree(
            cloneDir: URL(fileURLWithPath: "/tmp/clone"), repoName: "repo", prNumber: 9)

        XCTAssertEqual(head, "abc1234def")
        // Existing worktree: no prune/add. Fetch runs in the worktree with no
        // destination branch (git refuses to fetch into a checked-out branch),
        // then reset moves it — but only after checking the head actually
        // moved and that nothing uncommitted would be destroyed.
        XCTAssertEqual(fake.calls.map(\.arguments), [
            ["fetch", "origin", "pull/9/head"],
            ["rev-parse", "FETCH_HEAD"],
            ["rev-parse", "HEAD"],
            ["status", "--porcelain", "--untracked-files=no"],
            ["reset", "--hard", "FETCH_HEAD"],
            ["rev-parse", "HEAD"],
        ])
    }

    /// The PR has not moved, so there is nothing to reset to — and resetting
    /// anyway is how re-opening a PR used to wipe an applied fix out of the
    /// checkout.
    func testRefreshSkipsTheResetWhenTheHeadHasNotMoved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = dir.appendingPathComponent("repo-pr9")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = FakeProcessRunner()
        fake.responses = [
            ProcessResult(stdout: "", stderr: "", exitCode: 0),
            ProcessResult(stdout: "same\n", stderr: "", exitCode: 0),  // FETCH_HEAD
            ProcessResult(stdout: "same\n", stderr: "", exitCode: 0),  // HEAD
        ]
        let mgr = manager(fake, baseDir: dir, repoName: "repo")
        let head = try await mgr.refreshWorktree(
            cloneDir: URL(fileURLWithPath: "/tmp/clone"), repoName: "repo", prNumber: 9)

        XCTAssertEqual(head, "same")
        XCTAssertFalse(fake.calls.contains { $0.arguments.first == "reset" })
    }

    /// New commits exist, but so do uncommitted edits — the agent's "Fix it"
    /// writes exactly those, and promises they are the user's to review.
    func testRefreshRefusesToResetOverUncommittedWork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = dir.appendingPathComponent("repo-pr9")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = FakeProcessRunner()
        fake.responses = [
            ProcessResult(stdout: "", stderr: "", exitCode: 0),
            ProcessResult(stdout: "newhead\n", stderr: "", exitCode: 0),
            ProcessResult(stdout: "oldhead\n", stderr: "", exitCode: 0),
            ProcessResult(stdout: " M src/a.swift\n", stderr: "", exitCode: 0),
        ]
        let mgr = manager(fake, baseDir: dir, repoName: "repo")
        do {
            _ = try await mgr.refreshWorktree(
                cloneDir: URL(fileURLWithPath: "/tmp/clone"), repoName: "repo", prNumber: 9)
            XCTFail("expected localChanges")
        } catch {
            XCTAssertEqual(error as? WorktreeError, .localChanges)
        }
        XCTAssertFalse(fake.calls.contains { $0.arguments.first == "reset" })
    }

    /// A fork checkout's `origin` is the fork; the PR ref lives on the remote
    /// `gh` resolves, and fetching from the wrong one fails outright.
    func testRefreshFetchesFromTheNamedRemote() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = dir.appendingPathComponent("repo-pr9")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = FakeProcessRunner()
        fake.responses = [
            ProcessResult(stdout: "", stderr: "", exitCode: 0),
            ProcessResult(stdout: "a\n", stderr: "", exitCode: 0),
            ProcessResult(stdout: "a\n", stderr: "", exitCode: 0),
        ]
        let mgr = manager(fake, baseDir: dir, repoName: "repo")
        _ = try await mgr.refreshWorktree(
            cloneDir: URL(fileURLWithPath: "/tmp/clone"), repoName: "repo", prNumber: 9,
            remote: "upstream")
        XCTAssertEqual(fake.calls[0].arguments, ["fetch", "upstream", "pull/9/head"])
    }

    func testRefreshWorktreeThrowsWhenFetchFails() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = dir.appendingPathComponent("repo-pr9")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = FakeProcessRunner()
        fake.responses = [ProcessResult(stdout: "", stderr: "no such ref", exitCode: 1)]
        let mgr = manager(fake, baseDir: dir, repoName: "repo")
        do {
            _ = try await mgr.refreshWorktree(
                cloneDir: URL(fileURLWithPath: "/tmp/clone"), repoName: "repo", prNumber: 9)
            XCTFail("expected throw")
        } catch let e as WorktreeError {
            XCTAssertEqual(e, .commandFailed("no such ref"))
        } catch { XCTFail("wrong error") }
    }

    // MARK: - Against real git

    @discardableResult
    private func sh(_ args: [String], in dir: URL) async throws -> String {
        let r = try await DefaultProcessRunner().run("git", arguments: args, currentDirectory: dir)
        XCTAssertEqual(r.exitCode, 0, "git \(args.joined(separator: " ")): \(r.stderr)")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An "upstream" holding `main` and a PR ref, and the user's clone of it.
    private func makeUpstreamAndClone() async throws -> (upstream: URL, clone: URL, prHead: String) {
        let upstream = base.appendingPathComponent("upstream")
        let clone = base.appendingPathComponent("user/myrepo")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try await sh(["init", "--quiet", "-b", "main"], in: upstream)
        try await sh(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet",
                      "--allow-empty", "-m", "base"], in: upstream)
        try await sh(["checkout", "--quiet", "-b", "feature"], in: upstream)
        try "pr\n".write(to: upstream.appendingPathComponent("pr.txt"), atomically: true, encoding: .utf8)
        try await sh(["add", "pr.txt"], in: upstream)
        try await sh(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "pr"], in: upstream)
        let prHead = try await sh(["rev-parse", "HEAD"], in: upstream)
        try await sh(["update-ref", "refs/pull/7/head", prHead], in: upstream)
        try await sh(["checkout", "--quiet", "main"], in: upstream)
        try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try await sh(["clone", "--quiet", upstream.path, clone.path], in: base)
        return (upstream, clone, prHead)
    }

    /// The whole point of the private clone: opening a PR leaves the user's
    /// repository exactly as it was.
    func testCheckoutLeavesTheUsersRepositoryAlone() async throws {
        let (_, clone, prHead) = try await makeUpstreamAndClone()
        let branchesBefore = try await sh(["for-each-ref", "refs/heads"], in: clone)
        let mgr = WorktreeManager(runner: DefaultProcessRunner(),
                                  baseDir: base.appendingPathComponent("support/worktrees"))

        let wt = try await mgr.ensureWorktree(cloneDir: clone, repoName: "myrepo", prNumber: 7)

        let head = try await sh(["rev-parse", "HEAD"], in: wt)
        XCTAssertEqual(head, prHead)
        // The base branch resolves in the checkout without a fetch.
        try await sh(["rev-parse", "--verify", "origin/main"], in: wt)
        let worktrees = try await sh(["worktree", "list", "--porcelain"], in: clone)
        XCTAssertEqual(worktrees.components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.count, 1)
        let branchesAfter = try await sh(["for-each-ref", "refs/heads"], in: clone)
        XCTAssertEqual(branchesAfter, branchesBefore)

        // A later refresh fetches through the private clone's own remote.
        let refreshed = try await mgr.refreshWorktree(cloneDir: clone, repoName: "myrepo", prNumber: 7)
        XCTAssertEqual(refreshed, prHead)
    }

    /// Earlier versions hung worktrees and `difft-pr-*` branches off the
    /// user's clone. The first checkout through the private clone takes back
    /// the clean ones and leaves one holding an applied fix.
    func testFirstCheckoutRemovesLegacyWorktreesAndBranches() async throws {
        let (_, clone, _) = try await makeUpstreamAndClone()
        let worktreesDir = base.appendingPathComponent("support/worktrees")
        try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        try await sh(["fetch", "--quiet", "origin", "+pull/7/head:difft-pr-7"], in: clone)
        try await sh(["branch", "difft-pr-8", "difft-pr-7"], in: clone)
        try await sh(["branch", "difft-pr-9", "difft-pr-7"], in: clone)
        let clean = worktreesDir.appendingPathComponent("myrepo-pr8").path
        let dirty = worktreesDir.appendingPathComponent("myrepo-pr9").path
        try await sh(["worktree", "add", "--quiet", clean, "difft-pr-8"], in: clone)
        try await sh(["worktree", "add", "--quiet", dirty, "difft-pr-9"], in: clone)
        try "fix\n".write(toFile: dirty + "/pr.txt", atomically: true, encoding: .utf8)

        let mgr = WorktreeManager(runner: DefaultProcessRunner(), baseDir: worktreesDir)
        _ = try await mgr.ensureWorktree(cloneDir: clone, repoName: "myrepo", prNumber: 7)

        let worktrees = try await sh(["worktree", "list", "--porcelain"], in: clone)
        XCTAssertFalse(worktrees.contains(clean))
        XCTAssertTrue(worktrees.contains(dirty))
        let branches = try await sh(["for-each-ref", "--format=%(refname:short)", "refs/heads/difft-pr-*"], in: clone)
        XCTAssertEqual(branches, "difft-pr-9")
    }
}
