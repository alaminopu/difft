import Foundation

public enum WorktreeError: Error, Equatable, LocalizedError {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "git command failed" : trimmed
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

    public func ensureWorktree(cloneDir: URL, repoName: String, prNumber: Int) async throws -> URL {
        let target = worktreeURL(repoName: repoName, prNumber: prNumber)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }
        let branch = "difft-pr-\(prNumber)"
        let prune = try await runner.run("git", arguments: ["worktree", "prune"], currentDirectory: cloneDir)
        guard prune.exitCode == 0 else { throw WorktreeError.commandFailed(prune.stderr) }
        let fetch = try await runner.run("git", arguments: ["fetch", "origin", "+pull/\(prNumber)/head:\(branch)"], currentDirectory: cloneDir)
        guard fetch.exitCode == 0 else { throw WorktreeError.commandFailed(fetch.stderr) }
        let add = try await runner.run("git", arguments: ["worktree", "add", target.path, branch], currentDirectory: cloneDir)
        guard add.exitCode == 0 else { throw WorktreeError.commandFailed(add.stderr) }
        return target
    }

    /// Re-fetches the PR head into an existing worktree and hard-resets to
    /// it, so a PR opened earlier picks up commits pushed since. Returns the
    /// resulting HEAD sha. Creates the worktree first if it is missing.
    @discardableResult
    public func refreshWorktree(cloneDir: URL, repoName: String, prNumber: Int) async throws -> String {
        let target = try await ensureWorktree(cloneDir: cloneDir, repoName: repoName, prNumber: prNumber)
        // Fetch from inside the worktree without naming a destination branch:
        // git refuses to fetch into a branch that is checked out somewhere.
        // FETCH_HEAD then holds the PR head, and reset moves both the working
        // copy and the checked-out branch to it.
        let fetch = try await runner.run(
            "git", arguments: ["fetch", "origin", "pull/\(prNumber)/head"],
            currentDirectory: target)
        guard fetch.exitCode == 0 else { throw WorktreeError.commandFailed(fetch.stderr) }
        let reset = try await runner.run(
            "git", arguments: ["reset", "--hard", "FETCH_HEAD"], currentDirectory: target)
        guard reset.exitCode == 0 else { throw WorktreeError.commandFailed(reset.stderr) }
        let head = try await runner.run(
            "git", arguments: ["rev-parse", "HEAD"], currentDirectory: target)
        guard head.exitCode == 0 else { throw WorktreeError.commandFailed(head.stderr) }
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func prune(olderThan days: Int) throws {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let contents = (try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if modified < cutoff { try fm.removeItem(at: url) }
        }
    }
}
