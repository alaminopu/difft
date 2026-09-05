import SwiftUI
import DifftCore
import DifftServices

@MainActor
final class AppModel: ObservableObject {
    @Published var repoDir: URL? {
        didSet { UserDefaults.standard.set(repoDir?.path, forKey: "repoDir") }
    }
    @Published var prs: [PullRequest] = []
    @Published var session: ReviewSession?
    @Published var files: [FileDiff] = [] {
        // The tree is derived purely from `files`, but the sidebar rebuilt it
        // inside its `body` — so every file click, refresh flag and agent
        // status change paid for a full rebuild. Derive it once, here.
        didSet { fileTree = FileTreeNode.build(from: files) }
    }
    @Published private(set) var fileTree: [FileTreeNode] = []
    @Published var comments: [ReviewComment] = []
    @Published var commits: [Commit] = []
    /// The PR being opened, so the list and centre pane can say so. Opening
    /// waits on `gh`, and without this the app looked frozen on click.
    @Published var openingPRNumber: Int?
    /// Comments and commits arrive after the diff; the overview shows their
    /// counts, so it needs to know they are still on the way.
    @Published var isLoadingDetails = false
    /// Signed-in login, so a comment card knows whether it is the user's own
    /// and can offer editing. nil until the first lookup succeeds.
    @Published private(set) var currentUserLogin: String?
    /// "owner/name" for the open checkout, published so markdown bodies can
    /// build commit links.
    @Published private(set) var repoSlug: String?
    /// Files changed by the single commit currently drilled into, kept apart
    /// from `files` so opening a commit never disturbs the PR-wide diff.
    @Published var commitFiles: [FileDiff] = []
    @Published var isLoadingCommit = false
    @Published var toolCheck: (gh: Bool, ghAuth: Bool, claude: Bool)?
    @Published var errorBanner: String?
    /// Set by the overview's Explain button; consumed by the assistant panel.
    @Published var pendingExplainDiff = false
    @Published var isRefreshing = false
    /// Short transient result of the last refresh, shown in the overview.
    @Published var refreshNote: String?
    /// Head sha of the diff currently shown, so a refresh can report whether
    /// anything actually changed.
    @Published var currentHead: String?

    /// One controller for the whole app: it used to live inside the assistant
    /// panel, so hiding and showing the panel built a second controller while
    /// the first kept running — the visible tab then had no idea a run was
    /// its own, and lost its streaming text and tool activity.
    private(set) lazy var agent: AgentController = AgentController(model: self)

    let github = GitHubService()
    let sessionStore: SessionStore
    let processRunner = DefaultProcessRunner()

    static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Difft")
    }

    init() {
        sessionStore = SessionStore(directory: Self.appSupportDir.appendingPathComponent("sessions"))
        if let path = UserDefaults.standard.string(forKey: "repoDir") {
            repoDir = URL(fileURLWithPath: path)
        }
        let worktreesDir = Self.appSupportDir.appendingPathComponent("worktrees")
        Task.detached(priority: .utility) {
            try? WorktreeManager(runner: DefaultProcessRunner(), baseDir: worktreesDir)
                .prune(olderThan: 7)
        }
    }

    var repoName: String { repoDir?.lastPathComponent ?? "" }

    func checkTools() async {
        let gh = await github.checkAvailability()
        let claude = (try? await processRunner.run("which", arguments: ["claude"], currentDirectory: nil))?.exitCode == 0
        toolCheck = (gh.ghInstalled, gh.ghAuthed, claude)
    }

    func loadPRs() async {
        guard let repoDir else { return }
        // Also the point a repo becomes known, which is what the login
        // lookup needs; at launch there may not be one yet.
        Task { await loadCurrentUser() }
        Task { _ = await nameWithOwner(repoDir: repoDir) }
        do { prs = try await github.listPRs(repoDir: repoDir); errorBanner = nil }
        catch { errorBanner = "Failed to list PRs: \(error.localizedDescription)" }
    }

    /// PR currently being opened; a second tap (double-click, or a tap on a
    /// different PR mid-open) is ignored instead of racing the first — two
    /// interleaved opens can pair one PR's files with another's session.
    private var openingPR: Int?

    /// "owner/name" costs its own ~0.5s `gh` call and cannot change while a
    /// repo is open, so it is fetched once per checkout rather than on every
    /// open and every refresh.
    private var cachedNameWithOwner: (dir: URL, value: String)?

    private func nameWithOwner(repoDir: URL) async -> String? {
        if let cached = cachedNameWithOwner, cached.dir == repoDir { return cached.value }
        guard let value = try? await github.nameWithOwner(repoDir: repoDir) else { return nil }
        cachedNameWithOwner = (repoDir, value)
        repoSlug = value
        return value
    }

    /// IntelliJ-style full-file diff: check the PR out into its worktree and
    /// diff against the base branch with unlimited context, so every line of
    /// each changed file renders (changes highlighted inline). Falls back to
    /// `gh pr diff`'s 3-line-context hunks when any step fails.
    private func fetchFullContextDiff(repoDir: URL, pr: PullRequest) async -> [FileDiff]? {
        guard let base = pr.baseRefName else { return nil }
        do {
            let worktrees = WorktreeManager(
                runner: processRunner,
                baseDir: Self.appSupportDir.appendingPathComponent("worktrees"))
            let wt = try await worktrees.ensureWorktree(
                cloneDir: repoDir, repoName: repoName, prNumber: pr.number)
            // Fetch the base only when its ref is missing; when it exists,
            // refresh it in the background instead of on the open's critical
            // path (a slightly stale merge-base is fine for one open).
            let haveBase = try await processRunner.run(
                "git", arguments: ["rev-parse", "--verify", "--quiet", "origin/\(base)"],
                currentDirectory: wt)
            if haveBase.exitCode != 0 {
                let fetch = try await processRunner.run(
                    "git", arguments: ["fetch", "origin", base], currentDirectory: wt)
                guard fetch.exitCode == 0 else { return nil }
            } else {
                let runner = processRunner
                Task.detached(priority: .utility) {
                    _ = try? await runner.run("git", arguments: ["fetch", "origin", base],
                                              currentDirectory: wt)
                }
            }
            let diff = try await processRunner.run(
                "git", arguments: ["diff", "-U100000", "--merge-base", "origin/\(base)", "HEAD"],
                currentDirectory: wt)
            guard diff.exitCode == 0, !diff.stdout.isEmpty else { return nil }
            // Parsing a multi-megabyte full-context diff on the main actor
            // froze the UI for the whole open.
            let text = diff.stdout
            let parsed = await Task.detached(priority: .userInitiated) {
                DiffParser.parse(text)
            }.value
            return parsed.isEmpty ? nil : parsed
        } catch { return nil }
    }

    func openPR(_ pr: PullRequest) async {
        guard let repoDir, openingPR == nil else { return }
        openingPR = pr.number
        openingPRNumber = pr.number
        isLoadingDetails = true
        defer { openingPR = nil; openingPRNumber = nil; isLoadingDetails = false }
        // The previous PR's comments and commits must not linger while this
        // one loads — they would be attributed to the wrong PR on screen.
        comments = []
        commits = []
        do {
            // Comments (REST + GraphQL threads) and commits load concurrently
            // with the diff instead of after it.
            async let commentsTask = loadComments(repoDir: repoDir, number: pr.number)
            async let commitsTask = loadCommits(repoDir: repoDir, number: pr.number)
            if let full = await fetchFullContextDiff(repoDir: repoDir, pr: pr) {
                files = full
            } else {
                files = try await github.fetchDiff(repoDir: repoDir, number: pr.number)
            }

            // Show the PR as soon as its diff exists. Waiting for the `gh`
            // round-trips first left the window unchanged for well over a
            // second after the click, with the diff already in hand.
            let data = sessionStore.load(repo: repoName, prNumber: pr.number)
                ?? SessionData(pr: pr, repoDir: repoDir.path, viewedFiles: [], chat: [], findings: [], verdict: nil)
            session = ReviewSession(data: data)
            // Land on the PR overview; the user picks a file from the tree.
            session?.selectedFile = nil
            errorBanner = nil
            openingPRNumber = nil

            comments = await commentsTask
            commits = await commitsTask
            isLoadingDetails = false
            currentHead = try? await processRunner.run(
                "git", arguments: ["rev-parse", "HEAD"],
                currentDirectory: Self.appSupportDir
                    .appendingPathComponent("worktrees/\(repoName)-pr\(pr.number)")
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { errorBanner = "Failed to open PR #\(pr.number): \(error.localizedDescription)" }
    }

    /// Loads the diff a single commit introduced, against its own parent,
    /// with the same unlimited context the PR diff uses. Reads the PR's
    /// worktree, which is the only checkout guaranteed to hold the commit.
    func openCommit(_ commit: Commit) async {
        guard let session else { return }
        session.selectedCommit = commit
        session.selectedCommitFile = nil
        commitFiles = []
        isLoadingCommit = true
        defer { isLoadingCommit = false }
        let worktree = Self.appSupportDir
            .appendingPathComponent("worktrees/\(repoName)-pr\(session.data.pr.number)")
        guard let r = try? await processRunner.run(
                "git", arguments: ["show", "--format=", "-U100000", commit.sha],
                currentDirectory: worktree),
              r.exitCode == 0 else {
            errorBanner = "Failed to load commit \(commit.shortSHA)"
            return
        }
        // Parsing a full-context diff on the main actor freezes the UI, the
        // same reason the PR diff parses off it.
        let text = r.stdout
        commitFiles = await Task.detached(priority: .userInitiated) {
            DiffParser.parse(text)
        }.value
        session.selectedCommitFile = commitFiles.first?.path
        errorBanner = nil
    }

    /// Returns the centre pane to the PR overview from wherever it is. Every
    /// way back routes through here so no caller can reset three of the four
    /// pieces of state and leave the fourth behind.
    func showOverview() {
        session?.selectedFile = nil
        session?.showComments = false
        session?.showCommits = false
        closeCommit()
    }

    /// Opens the commit a review comment referred to.
    ///
    /// Usually it is one of the PR's own commits, but a comment can name one
    /// from the base branch or another PR, so an unmatched SHA is looked up
    /// in the worktree before giving up. If even git does not know it — a
    /// commit from a fork, say — the reader is sent to GitHub rather than
    /// shown nothing.
    func openCommit(sha: String) async {
        guard let session else { return }

        if let known = commits.first(where: { $0.sha.hasPrefix(sha) }) {
            session.showComments = false
            session.showCommits = true
            await openCommit(known)
            return
        }

        let worktree = Self.appSupportDir
            .appendingPathComponent("worktrees/\(repoName)-pr\(session.data.pr.number)")
        // %x1f separates fields; the subject and body can contain anything.
        let format = "%H%x1f%an%x1f%aI%x1f%s%x1f%b"
        if let r = try? await processRunner.run(
                "git", arguments: ["show", "-s", "--format=\(format)", sha],
                currentDirectory: worktree),
           r.exitCode == 0 {
            let parts = r.stdout.components(separatedBy: "\u{1f}")
            if parts.count >= 4 {
                let resolved = Commit(sha: parts[0], subject: parts[3],
                                      body: parts.count > 4 ? parts[4] : "",
                                      author: parts[1], date: parts[2])
                session.showComments = false
                session.showCommits = true
                await openCommit(resolved)
                return
            }
        }

        if let slug = repoSlug, let url = URL(string: "https://github.com/\(slug)/commit/\(sha)") {
            NSWorkspace.shared.open(url)
        } else {
            errorBanner = "Commit \(sha) is not in this checkout."
        }
    }

    func closeCommit() {
        session?.selectedCommit = nil
        session?.selectedCommitFile = nil
        commitFiles = []
    }

    /// Newest first, the way GitHub and `git log` present history. Failure
    /// yields an empty list rather than throwing — commits are secondary to
    /// the diff, and losing them should not fail opening the PR.
    private func loadCommits(repoDir: URL, number: Int) async -> [Commit] {
        let loaded = (try? await github.fetchCommits(repoDir: repoDir, number: number)) ?? []
        return loaded.sorted { $0.date > $1.date }
    }

    private func loadComments(repoDir: URL, number: Int) async -> [ReviewComment] {
        guard let owner = await nameWithOwner(repoDir: repoDir) else {
            return (try? await github.fetchComments(repoDir: repoDir, number: number)) ?? []
        }
        // The REST comments and the GraphQL thread states do not depend on
        // each other; running them in sequence doubled the wait.
        async let commentsTask = try? await github.fetchComments(repoDir: repoDir, number: number)
        async let threadsTask = try? await github.fetchThreadInfo(
            repoDir: repoDir, number: number, nameWithOwner: owner)
        var loaded = await commentsTask ?? []
        if let threads = await threadsTask {
            for i in loaded.indices {
                if let info = threads[loaded[i].id] {
                    loaded[i].threadID = info.threadID
                    loaded[i].resolved = info.resolved
                }
            }
        }
        return loaded
    }

    /// Looked up once per launch; the signed-in account does not change
    /// under us, and it costs its own `gh` process.
    func loadCurrentUser() async {
        guard currentUserLogin == nil, let repoDir else { return }
        currentUserLogin = try? await github.currentUser(repoDir: repoDir)
    }

    func canEdit(_ comment: ReviewComment) -> Bool {
        guard let me = currentUserLogin else { return false }
        return comment.author == me
    }

    func edit(_ comment: ReviewComment, body: String) async {
        guard let repoDir, let session else { return }
        do {
            try await github.updateComment(repoDir: repoDir, commentID: comment.id, body: body)
            comments = await loadComments(repoDir: repoDir, number: session.data.pr.number)
            errorBanner = nil
        } catch {
            errorBanner = "Failed to edit comment: \(error.localizedDescription)"
        }
    }

    func delete(_ comment: ReviewComment) async {
        guard let repoDir, let session else { return }
        do {
            try await github.deleteComment(repoDir: repoDir, commentID: comment.id)
            comments = await loadComments(repoDir: repoDir, number: session.data.pr.number)
            errorBanner = nil
        } catch {
            errorBanner = "Failed to delete comment: \(error.localizedDescription)"
        }
    }

    /// Starts a review thread on the selected lines of a file.
    ///
    /// GitHub anchors a comment to a commit, and rejects one whose line
    /// numbers do not belong to that commit's diff — so this uses the head
    /// the worktree is actually checked out at, which is what the line
    /// numbers on screen were read from.
    func addComment(path: String, startLine: Int, endLine: Int, body: String) async {
        guard let repoDir, let session else { return }
        guard let head = currentHead, !head.isEmpty else {
            errorBanner = "Cannot comment yet: still resolving the PR's head commit."
            return
        }
        do {
            try await github.createComment(
                repoDir: repoDir, number: session.data.pr.number, commitID: head,
                path: path, line: endLine,
                startLine: startLine < endLine ? startLine : nil, body: body)
            comments = await loadComments(repoDir: repoDir, number: session.data.pr.number)
            errorBanner = nil
        } catch {
            // The usual cause is commenting on a line outside the diff, which
            // GitHub refuses; say so rather than showing a bare API error.
            errorBanner = "Failed to add comment: \(error.localizedDescription)"
        }
    }

    func reply(to comment: ReviewComment, body: String) async {
        guard let repoDir, let session else { return }
        do {
            try await github.replyToComment(repoDir: repoDir, number: session.data.pr.number,
                                            commentID: comment.id, body: body)
            comments = await loadComments(repoDir: repoDir, number: session.data.pr.number)
            errorBanner = nil
        } catch {
            errorBanner = "Failed to reply: \(error.localizedDescription)"
        }
    }

    func resolve(_ comment: ReviewComment) async {
        guard let repoDir, let session, let threadID = comment.threadID else { return }
        do {
            try await github.resolveThread(repoDir: repoDir, threadID: threadID)
            comments = await loadComments(repoDir: repoDir, number: session.data.pr.number)
            errorBanner = nil
        } catch {
            errorBanner = "Failed to resolve: \(error.localizedDescription)"
        }
    }

    /// Re-fetches the PR's commits into its worktree, re-parses the diff and
    /// reloads comments — keeping viewed files, chat, and findings intact.
    func refreshPR() async {
        guard let repoDir, let session, !isRefreshing else { return }
        let pr = session.data.pr
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let worktrees = WorktreeManager(
                runner: processRunner,
                baseDir: Self.appSupportDir.appendingPathComponent("worktrees"))
            let previousHead = currentHead
            let head = try await worktrees.refreshWorktree(
                cloneDir: repoDir, repoName: repoName, prNumber: pr.number)
            async let commentsTask = loadComments(repoDir: repoDir, number: pr.number)
            async let commitsTask = loadCommits(repoDir: repoDir, number: pr.number)
            if let full = await fetchFullContextDiff(repoDir: repoDir, pr: pr) {
                files = full
            } else {
                files = try await github.fetchDiff(repoDir: repoDir, number: pr.number)
            }
            comments = await commentsTask
            commits = await commitsTask
            currentHead = head
            // Keep the open file if it still exists in the refreshed diff.
            if let selected = session.selectedFile,
               !files.contains(where: { $0.path == selected }) {
                session.selectedFile = nil
            }
            refreshNote = (previousHead == nil || previousHead == head)
                ? "Already up to date"
                : "Updated to \(String(head.prefix(7)))"
            errorBanner = nil
        } catch {
            errorBanner = "Failed to refresh PR #\(pr.number): \(error.localizedDescription)"
        }
    }

    func markViewed(_ path: String, viewed: Bool) {
        guard let session else { return }
        if viewed { session.data.viewedFiles.insert(path) } else { session.data.viewedFiles.remove(path) }
        do {
            try sessionStore.save(session.data)
            errorBanner = nil
        } catch {
            errorBanner = "Failed to save session: \(error.localizedDescription)"
        }
    }

    /// Snapshots session/files state on the main actor, then does the actual
    /// screenshot reads, HTML render, and disk write off the main actor in a
    /// detached task — this touches disk (potentially many evidence PNGs) and
    /// must not block the UI.
    func generateReport(evidence: [URL]) async throws -> URL {
        guard let session else { throw GitHubServiceError.commandFailed("no session") }
        let sessionData = session.data
        let filesSnapshot = files
        let repo = repoName
        return try await Task.detached(priority: .userInitiated) {
            let screenshots: [(name: String, pngData: Data)] = evidence.compactMap { url in
                (try? Data(contentsOf: url)).map { (url.lastPathComponent, $0) }
            }
            let html = ReportBuilder.html(for: ReportInput(session: sessionData, files: filesSnapshot, screenshots: screenshots))
            let url = ReportBuilder.defaultURL(repoName: repo, prNumber: sessionData.pr.number, date: Date())
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(html.utf8).write(to: url)
            return url
        }.value
    }
}
