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

/// Checks pull requests out where the user's own repository never sees them.
///
/// Worktrees used to hang off the user's clone, so every PR opened left a
/// `difft-pr-N` branch and a worktree entry in their repository — in
/// `git branch`, in `git worktree list`, in their IDE. Each repository now
/// gets a bare clone of Difft's own under `reposDir`, made from the local
/// clone with hardlinked objects so it costs seconds and next to no disk, and
/// the PR worktrees belong to that.
public final class WorktreeManager: Sendable {
    private let runner: ProcessRunning
    private let baseDir: URL
    private let reposDir: URL
    /// - Parameter reposDir: where the private clones live. Defaults to a
    ///   `repos` directory beside `baseDir`, outside it so the worktree
    ///   sweep in `prune(olderThan:)` never mistakes one for a checkout.
    public init(runner: ProcessRunning, baseDir: URL, reposDir: URL? = nil) {
        self.runner = runner; self.baseDir = baseDir
        self.reposDir = reposDir ?? baseDir.deletingLastPathComponent().appendingPathComponent("repos")
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.reposDir, withIntermediateDirectories: true)
    }

    public func worktreeURL(repoName: String, prNumber: Int) -> URL {
        baseDir.appendingPathComponent("\(repoName)-pr\(prNumber)")
    }

    public func repoURL(repoName: String) -> URL {
        reposDir.appendingPathComponent("\(repoName).git")
    }

    /// The PR's checkout with every file written, for anything that reads the
    /// working tree — which is what Claude does.
    public func ensureWorktree(cloneDir: URL, repoName: String, prNumber: Int,
                               remote: String = "origin") async throws -> URL {
        let target = try await makeWorktree(cloneDir: cloneDir, repoName: repoName,
                                            prNumber: prNumber, remote: remote,
                                            expectedHead: nil).url
        try await completeCheckout(at: target)
        return target
    }

    /// The checkout, and whether this call created it.
    ///
    /// A new checkout is made without its files. Everything that opening a PR
    /// needs — the diff, the head, the attributes — reads git's objects and
    /// index, and writing out a large repository's files was the slowest
    /// step of the open: 1.4–2.1s for baserow's ten thousand, against 0.1s
    /// for the index alone. `completeCheckout(at:)` writes them, and every
    /// path that reads the working tree calls it first.
    ///
    /// - Parameter expectedHead: the commit GitHub reports as the PR head.
    ///   When `prefetch` has already brought it into the repository, the
    ///   checkout is made from it without going to the network.
    private func makeWorktree(cloneDir: URL, repoName: String, prNumber: Int,
                              remote: String, expectedHead: String?) async throws -> (url: URL, created: Bool) {
        let repo = try await ensureRepo(cloneDir: cloneDir, repoName: repoName, remote: remote)
        let target = worktreeURL(repoName: repoName, prNumber: prNumber)
        if FileManager.default.fileExists(atPath: target.path) {
            if Self.isOrphaned(target) {
                // Its repository was swept away beneath it; git can do
                // nothing in it, so start over.
                try? FileManager.default.removeItem(at: target)
            } else {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                return (target, false)
            }
        }
        let branch = "difft-pr-\(prNumber)"
        let prune = try await runner.run("git", arguments: ["worktree", "prune"], currentDirectory: repo)
        guard prune.exitCode == 0 else { throw WorktreeError.commandFailed(prune.stderr) }
        if let expectedHead, await hasCommit(expectedHead, in: repo) {
            _ = try await git(["branch", "-f", branch, expectedHead], in: repo)
        } else {
            let fetch = try await runner.run("git", arguments: ["fetch", remote, "+pull/\(prNumber)/head:\(branch)"], currentDirectory: repo)
            guard fetch.exitCode == 0 else { throw WorktreeError.commandFailed(fetch.stderr) }
        }
        // Marked before the checkout exists, so a checkout cut short — the app
        // quit between here and `completeCheckout` — is still known to be
        // missing its files.
        markCheckoutPending(target)
        let add = try await runner.run("git", arguments: ["worktree", "add", "--no-checkout", target.path, branch], currentDirectory: repo)
        guard add.exitCode == 0 else {
            clearCheckoutPending(target)
            throw WorktreeError.commandFailed(add.stderr)
        }
        // The index, without the files: cheap, and it is what `check-attr
        // --cached` reads the repository's attributes from.
        let index = try await runner.run("git", arguments: ["read-tree", "HEAD"], currentDirectory: target)
        guard index.exitCode == 0 else { throw WorktreeError.commandFailed(index.stderr) }
        return (target, true)
    }

    // MARK: - Deferred checkout

    /// Where the "files not written yet" markers live: beside the checkouts
    /// rather than among them, so the age sweep never takes one for a
    /// checkout, and outside the working tree, where Claude would see it.
    private var pendingDir: URL {
        reposDir.deletingLastPathComponent().appendingPathComponent("pending-checkouts")
    }

    private func pendingMarker(_ target: URL) -> URL {
        pendingDir.appendingPathComponent(target.lastPathComponent)
    }

    private func markCheckoutPending(_ target: URL) {
        try? FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pendingMarker(target).path, contents: nil)
    }

    private func clearCheckoutPending(_ target: URL) {
        try? FileManager.default.removeItem(at: pendingMarker(target))
    }

    /// Writes out the files of a checkout made without them. Returns at once
    /// when there is nothing to write, so any caller may use it as a guard.
    public func completeCheckout(repoName: String, prNumber: Int) async throws {
        try await completeCheckout(at: worktreeURL(repoName: repoName, prNumber: prNumber))
    }

    private func completeCheckout(at target: URL) async throws {
        guard FileManager.default.fileExists(atPath: pendingMarker(target).path) else { return }
        let runner = runner, marker = pendingMarker(target)
        // One writer per checkout: the background completion after an open,
        // a Claude run and a refresh can all ask at once, and two `reset`s in
        // one checkout fight over its index lock.
        try await Self.checkouts.run(target.path) {
            guard FileManager.default.fileExists(atPath: marker.path) else { return }
            // Nothing in this checkout is anyone's work yet: it has never had
            // files. The reset writes HEAD's.
            let r = try await runner.run("git", arguments: ["reset", "--hard", "--quiet", "HEAD"],
                                         currentDirectory: target)
            guard r.exitCode == 0 else { throw WorktreeError.commandFailed(r.stderr) }
            try? FileManager.default.removeItem(at: marker)
        }
    }

    private static let checkouts = CheckoutGate()

    // MARK: - Prefetch

    /// Brings the given PR heads into Difft's clone ahead of time, in one
    /// fetch, so opening any of them needs no network at all.
    ///
    /// Fetching a PR's head was most of what was left of opening it — 1.7 to
    /// 2.6s on baserow, nearly all handshake — and one fetch for thirty heads
    /// costs about what one fetch for one does. Heads already present are
    /// skipped, so the list's minute-by-minute reload costs a local lookup
    /// unless someone pushed. Returns how many heads were fetched.
    @discardableResult
    public func prefetch(cloneDir: URL, repoName: String, remote: String = "origin",
                         heads: [Int: String]) async throws -> Int {
        guard !heads.isEmpty else { return 0 }
        let repo = try await ensureRepo(cloneDir: cloneDir, repoName: repoName, remote: remote)
        let present = await presentCommits(Array(heads.values), in: repo)
        let missing = heads.filter { !present.contains($0.value) }.keys.sorted()
        guard !missing.isEmpty else { return 0 }
        // Under refs of Difft's own, so they survive gc and stay out of the
        // `difft-pr-*` branches the checkouts sit on. FETCH_HEAD is left
        // alone: a PR open fetching at the same moment reads its own.
        let specs = missing.map { "+pull/\($0)/head:refs/difft/pr/\($0)" }
        _ = try await git(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote] + specs,
                          in: repo)
        return missing.count
    }

    /// Which of `oids` the repository already has, in one process.
    private func presentCommits(_ oids: [String], in repo: URL) async -> Set<String> {
        let input = Data(oids.map { $0 + "^{commit}\n" }.joined().utf8)
        guard let r = try? await runner.run("git", arguments: ["cat-file", "--batch-check"],
                                            currentDirectory: repo, stdin: input),
              r.exitCode == 0 else { return [] }
        // "<oid> commit <size>" for a hit, "<name> missing" for a miss, in
        // input order.
        var present = Set<String>()
        for (oid, line) in zip(oids, r.stdout.split(separator: "\n")) where !line.hasSuffix(" missing") {
            present.insert(oid)
        }
        return present
    }

    private func hasCommit(_ oid: String, in dir: URL) async -> Bool {
        guard !oid.isEmpty,
              let r = try? await runner.run("git", arguments: ["cat-file", "-e", "\(oid)^{commit}"],
                                            currentDirectory: dir) else { return false }
        return r.exitCode == 0
    }

    /// Difft's private clone of `cloneDir`, made on first use.
    ///
    /// It is bare, points `remote` at the same URL the user's clone does, and
    /// starts with a copy of the user's remote-tracking branches so the base
    /// branch resolves without a fetch.
    private func ensureRepo(cloneDir: URL, repoName: String, remote: String) async throws -> URL {
        let fm = FileManager.default
        let repo = repoURL(repoName: repoName)
        if fm.fileExists(atPath: repo.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: repo.path)
            return repo
        }

        let url = try await git(["remote", "get-url", remote], in: cloneDir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Built under a temporary name and moved into place, so a clone cut
        // short is never taken for a finished one.
        let partial = reposDir.appendingPathComponent(".\(repoName)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: partial) }
        // A local path clones by hardlinking the object files.
        _ = try await git(["clone", "--bare", "--quiet", cloneDir.path, partial.path], in: reposDir)
        _ = try await git(["remote", "remove", "origin"], in: partial)
        _ = try await git(["remote", "add", remote, url], in: partial)
        _ = try await git(["fetch", "--quiet", "--no-tags", cloneDir.path,
                           "+refs/remotes/\(remote)/*:refs/remotes/\(remote)/*"], in: partial)
        do {
            try fm.moveItem(at: partial, to: repo)
        } catch where fm.fileExists(atPath: repo.path) {
            // Another caller finished the same clone first.
            return repo
        }
        await removeLegacyCheckouts(from: cloneDir)
        return repo
    }

    /// Takes back what earlier versions left in the user's repository: the
    /// worktrees under `baseDir` and the `difft-pr-*` branches they sat on.
    ///
    /// Best effort, once per repository. A worktree with uncommitted edits
    /// holds an applied fix the user was told to review, so it stays until
    /// the age sweep removes it, and so does the branch it has checked out
    /// (git refuses to delete that one).
    private func removeLegacyCheckouts(from cloneDir: URL) async {
        let base = baseDir.resolvingSymlinksInPath().path + "/"
        if let list = try? await git(["worktree", "list", "--porcelain"], in: cloneDir) {
            let paths = list.split(separator: "\n")
                .filter { $0.hasPrefix("worktree ") }
                .map { String($0.dropFirst("worktree ".count)) }
                .filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(base) }
            for path in paths where !((try? await isDirty(URL(fileURLWithPath: path))) ?? true) {
                _ = try? await git(["worktree", "remove", "--force", path], in: cloneDir)
            }
        }
        _ = try? await git(["worktree", "prune"], in: cloneDir)
        if let branches = try? await git(["for-each-ref", "--format=%(refname:short)",
                                          "refs/heads/difft-pr-*"], in: cloneDir) {
            for branch in branches.split(separator: "\n") {
                _ = try? await git(["branch", "-D", String(branch)], in: cloneDir)
            }
        }
    }

    /// A worktree's `.git` is a file naming its entry in the repository it
    /// came from. When that entry is gone, so is the checkout.
    private static func isOrphaned(_ worktree: URL) -> Bool {
        guard let pointer = try? String(contentsOf: worktree.appendingPathComponent(".git"), encoding: .utf8),
              pointer.hasPrefix("gitdir: ") else { return false }
        let gitdir = pointer.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return !FileManager.default.fileExists(atPath: gitdir)
    }

    private func git(_ arguments: [String], in dir: URL) async throws -> String {
        let r = try await runner.run("git", arguments: arguments, currentDirectory: dir)
        guard r.exitCode == 0 else { throw WorktreeError.commandFailed(r.stderr) }
        return r.stdout
    }

    /// Re-fetches the PR head into an existing worktree and hard-resets to
    /// it, so a PR opened earlier picks up commits pushed since. Returns the
    /// resulting HEAD sha. Creates the worktree first if it is missing.
    ///
    /// - Parameters:
    ///   - expectedHead: the head GitHub reports. When the repository already
    ///     has it (see `prefetch`), it is used without a fetch. An explicit
    ///     refresh passes nil so that it asks the network.
    ///   - deferCheckout: leave a new checkout's files unwritten, for a caller
    ///     that only reads git's objects and will call `completeCheckout`.
    @discardableResult
    public func refreshWorktree(cloneDir: URL, repoName: String, prNumber: Int,
                                remote: String = "origin", expectedHead: String? = nil,
                                deferCheckout: Bool = false) async throws -> String {
        let (target, created) = try await makeWorktree(cloneDir: cloneDir, repoName: repoName,
                                                       prNumber: prNumber, remote: remote,
                                                       expectedHead: expectedHead)
        // A checkout made just now was fetched to make it. Fetching the same
        // head again was a second network round trip on every first open of a
        // PR — about 1.5s on a large repository — to learn nothing.
        if created {
            if !deferCheckout { try await completeCheckout(at: target) }
            return try await revParse("HEAD", in: target)
        }
        // A checkout with no files reads as every file deleted, which the
        // dirty check below would take for an applied fix.
        try await completeCheckout(at: target)

        let fetched: String
        let resetTarget: String
        if let expectedHead, await hasCommit(expectedHead, in: target) {
            fetched = expectedHead
            resetTarget = expectedHead
        } else {
            // Fetch from inside the worktree without naming a destination
            // branch: git refuses to fetch into a branch that is checked out
            // somewhere. FETCH_HEAD then holds the PR head, and reset moves
            // both the working copy and the checked-out branch to it.
            let fetch = try await runner.run(
                "git", arguments: ["fetch", remote, "pull/\(prNumber)/head"],
                currentDirectory: target)
            guard fetch.exitCode == 0 else { throw WorktreeError.commandFailed(fetch.stderr) }
            fetched = try await revParse("FETCH_HEAD", in: target)
            resetTarget = "FETCH_HEAD"
        }
        let current = try await revParse("HEAD", in: target)
        // Nothing moved: resetting would be pure destruction — it is how an
        // ordinary re-open used to wipe an applied fix out of the worktree.
        guard fetched != current else { return current }
        if try await isDirty(target) { throw WorktreeError.localChanges }

        let reset = try await runner.run(
            "git", arguments: ["reset", "--hard", resetTarget], currentDirectory: target)
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

    /// Deletes checkouts and private clones untouched for `days`, returning
    /// how many went.
    ///
    /// Background housekeeping only, run once at launch. A checkout the app is
    /// using is touched on every open, and so is its repository's clone, so
    /// the age test alone keeps both.
    @discardableResult
    public func prune(olderThan days: Int) throws -> Int {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let contents = [baseDir, reposDir].flatMap {
            (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
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

/// Runs at most one piece of work per key at a time; a caller arriving while
/// it runs waits for that run instead of starting another.
private actor CheckoutGate {
    private var running: [String: Task<Void, Error>] = [:]

    func run(_ key: String, _ work: @escaping @Sendable () async throws -> Void) async throws {
        if let existing = running[key] { return try await existing.value }
        let task = Task { try await work() }
        running[key] = task
        defer { running[key] = nil }
        try await task.value
    }
}
