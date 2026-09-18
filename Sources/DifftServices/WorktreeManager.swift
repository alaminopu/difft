import Foundation

public enum WorktreeError: Error, Equatable, LocalizedError {
    case commandFailed(String)
    /// The worktree has uncommitted edits and the PR head has moved on, so
    /// updating it would throw those edits away. The agent's "Fix it" writes
    /// exactly such edits, and it promises they are the user's to review.
    case localChanges

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "git command failed" : trimmed
        case .localChanges:
            return "This PR has new commits, but the checkout has uncommitted changes "
                + "(an applied fix). Showing it as it stands rather than discarding them."
        }
    }
}

public final class WorktreeManager: Sendable {
    private let runner: ProcessRunning
    private let baseDir: URL
    public init(runner: ProcessRunning, baseDir: URL) {
        self.runner = runner; self.baseDir = baseDir
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    public func worktreeURL(repoName: String, prNumber: Int) -> URL {
        baseDir.appendingPathComponent("\(repoName)-pr\(prNumber)")
    }

    public func ensureWorktree(cloneDir: URL, repoName: String, prNumber: Int,
                               remote: String = "origin") async throws -> URL {
        let target = worktreeURL(repoName: repoName, prNumber: prNumber)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }
        let branch = "difft-pr-\(prNumber)"
        let prune = try await runner.run("git", arguments: ["worktree", "prune"], currentDirectory: cloneDir)
        guard prune.exitCode == 0 else { throw WorktreeError.commandFailed(prune.stderr) }
        let fetch = try await runner.run("git", arguments: ["fetch", remote, "+pull/\(prNumber)/head:\(branch)"], currentDirectory: cloneDir)
        guard fetch.exitCode == 0 else { throw WorktreeError.commandFailed(fetch.stderr) }
        let add = try await runner.run("git", arguments: ["worktree", "add", target.path, branch], currentDirectory: cloneDir)
        guard add.exitCode == 0 else { throw WorktreeError.commandFailed(add.stderr) }
        return target
    }

    /// Re-fetches the PR head into an existing worktree and hard-resets to
    /// it, so a PR opened earlier picks up commits pushed since. Returns the
    /// resulting HEAD sha. Creates the worktree first if it is missing.
    @discardableResult
    public func refreshWorktree(cloneDir: URL, repoName: String, prNumber: Int,
                                remote: String = "origin") async throws -> String {
        let target = try await ensureWorktree(cloneDir: cloneDir, repoName: repoName,
                                              prNumber: prNumber, remote: remote)
        // Fetch from inside the worktree without naming a destination branch:
        // git refuses to fetch into a branch that is checked out somewhere.
        // FETCH_HEAD then holds the PR head, and reset moves both the working
        // copy and the checked-out branch to it.
        let fetch = try await runner.run(
            "git", arguments: ["fetch", remote, "pull/\(prNumber)/head"],
            currentDirectory: target)
        guard fetch.exitCode == 0 else { throw WorktreeError.commandFailed(fetch.stderr) }

        let fetched = try await revParse("FETCH_HEAD", in: target)
        let current = try await revParse("HEAD", in: target)
        // Nothing moved: resetting would be pure destruction — it is how an
        // ordinary re-open used to wipe an applied fix out of the worktree.
        guard fetched != current else { return current }
        if try await isDirty(target) { throw WorktreeError.localChanges }

        let reset = try await runner.run(
            "git", arguments: ["reset", "--hard", "FETCH_HEAD"], currentDirectory: target)
        guard reset.exitCode == 0 else { throw WorktreeError.commandFailed(reset.stderr) }
        return try await revParse("HEAD", in: target)
    }

    /// HEAD of an existing worktree without touching the network. Used when a
    /// refresh was declined so the caller still knows what it is showing.
    public func currentHead(repoName: String, prNumber: Int) async -> String? {
        let target = worktreeURL(repoName: repoName, prNumber: prNumber)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try? await revParse("HEAD", in: target)
    }

    private func revParse(_ ref: String, in dir: URL) async throws -> String {
        let r = try await runner.run("git", arguments: ["rev-parse", ref], currentDirectory: dir)
        guard r.exitCode == 0 else { throw WorktreeError.commandFailed(r.stderr) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tracked files modified, staged, or removed. Untracked files are not
    /// counted: build output and editor droppings must not block an update.
    private func isDirty(_ dir: URL) async throws -> Bool {
        let r = try await runner.run("git", arguments: ["status", "--porcelain", "--untracked-files=no"],
                                     currentDirectory: dir)
        guard r.exitCode == 0 else { return false }
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Deletes checkouts untouched for `days`, returning how many went.
    ///
    /// Background housekeeping only, run once at launch. A checkout the app is
    /// using is touched on every open, so the age test alone keeps it.
    @discardableResult
    public func prune(olderThan days: Int) throws -> Int {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let contents = (try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if modified < cutoff {
                try fm.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }
}
