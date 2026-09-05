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
    @Published var files: [FileDiff] = []
    @Published var comments: [ReviewComment] = []
    @Published var commits: [Commit] = []
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
        do { prs = try await github.listPRs(repoDir: repoDir); errorBanner = nil }
        catch { errorBanner = "Failed to list PRs: \(error.localizedDescription)" }
    }

    /// PR currently being opened; a second tap (double-click, or a tap on a
    /// different PR mid-open) is ignored instead of racing the first — two
    /// interleaved opens can pair one PR's files with another's session.
    private var openingPR: Int?

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
        defer { openingPR = nil }
        do {
            // Comments (REST + GraphQL threads) load concurrently with the
            // diff instead of after it.
            async let commentsTask = loadComments(repoDir: repoDir, number: pr.number)
            async let commitsTask = loadCommits(repoDir: repoDir, number: pr.number)
            if let full = await fetchFullContextDiff(repoDir: repoDir, pr: pr) {
                files = full
            } else {
                files = try await github.fetchDiff(repoDir: repoDir, number: pr.number)
            }
            comments = await commentsTask
            commits = await commitsTask
            currentHead = try? await processRunner.run(
                "git", arguments: ["rev-parse", "HEAD"],
                currentDirectory: Self.appSupportDir
                    .appendingPathComponent("worktrees/\(repoName)-pr\(pr.number)")
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let data = sessionStore.load(repo: repoName, prNumber: pr.number)
                ?? SessionData(pr: pr, repoDir: repoDir.path, viewedFiles: [], chat: [], findings: [], verdict: nil)
            session = ReviewSession(data: data)
            // Land on the PR overview; the user picks a file from the tree.
            session?.selectedFile = nil
            errorBanner = nil
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
        var loaded = (try? await github.fetchComments(repoDir: repoDir, number: number)) ?? []
        if let threads = try? await github.fetchThreadInfo(repoDir: repoDir, number: number) {
            for i in loaded.indices {
                if let info = threads[loaded[i].id] {
                    loaded[i].threadID = info.threadID
                    loaded[i].resolved = info.resolved
                }
            }
        }
        return loaded
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
