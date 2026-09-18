import SwiftUI
import DifftCore
import DifftServices

@MainActor
final class AppModel: ObservableObject {
    @Published var repoDir: URL? {
        didSet {
            UserDefaults.standard.set(repoDir?.path, forKey: "repoDir")
            // Authors belong to a repository; carrying them across would filter
            // the new list by people who have never touched it.
            prAuthors = []
            knownAuthors = []
            contributorsLoadedFor = nil
        }
    }
    @Published var prs: [PullRequest] = []
    /// Which PRs the list asks for, and what it asks for them by. Both live
    /// here rather than in the sidebar so the background refresh re-runs the
    /// query the user is actually looking at.
    @Published var prScope: PRScope = .open
    @Published var prSearch = ""
    /// Authors the list is narrowed to. Empty means everyone.
    @Published var prAuthors: Set<String> = []
    /// People the author filter can offer: the repository's contributors,
    /// most active first, plus anyone seen authoring a PR in this session.
    /// Ticking someone must not shrink the list to just them, which is what
    /// deriving it from the filtered results alone would do.
    @Published private(set) var knownAuthors: [String] = []
    @Published private(set) var isLoadingAuthors = false
    /// Contributors are a whole extra round trip, so they are fetched the
    /// first time the picker is opened rather than on every launch.
    private var contributorsLoadedFor: URL?
    @Published var isLoadingPRs = false
    /// Set when the query filled the page, so the list can say the result is
    /// a page rather than the answer.
    @Published var prsTruncated = false
    @Published var session: ReviewSession?
    @Published var files: [FileDiff] = [] {
        // The tree is derived purely from `files`, but the sidebar rebuilt it
        // inside its `body` — so every file click, refresh flag and agent
        // status change paid for a full rebuild. Derive it once, here.
        didSet { fileTree = FileTreeNode.build(from: files) }
    }
    @Published private(set) var fileTree: [FileTreeNode] = []

    /// Grouped per path rather than globally, so the counts match what the
    /// per-file comment view shows.
    private static func threadCounts(_ comments: [ReviewComment]) -> [String: Int] {
        var byPath: [String: [ReviewComment]] = [:]
        for comment in comments { byPath[comment.path, default: []].append(comment) }
        return byPath.mapValues { CommentThread.group($0).count }
    }
    @Published var comments: [ReviewComment] = [] {
        // Every file row in the sidebar used to filter the whole comment list
        // and group it, inside its own body — O(files x comments) on each
        // pass, paid again for every row the tree scrolled into view. Bucket
        // it once here instead.
        didSet {
            threadCountsByPath = Self.threadCounts(comments)
            commentsByPath = Dictionary(grouping: comments, by: \.path)
            threads = CommentThread.group(comments)
            unresolvedThreadCount = threads.count { !$0.resolved }
        }
    }
    /// Grouped once here rather than in each view's `body`.
    ///
    /// The comments pane recomputed this about six times per pass and the
    /// overview's button once per render — and `AppModel` publishes a dozen
    /// unrelated things, so every refresh flag and loading state paid for a
    /// full O(n log n) regroup of every comment on the PR.
    @Published private(set) var threads: [CommentThread] = []
    @Published private(set) var unresolvedThreadCount = 0
    /// Review-thread count per file path, for the sidebar's badge.
    @Published private(set) var threadCountsByPath: [String: Int] = [:]
    /// Comments bucketed by file, for the open diff.
    ///
    /// The diff container filtered the whole comment list inside its own body,
    /// so every font-size step, layout toggle and selection change on a PR with
    /// hundreds of comments walked all of them again.
    @Published private(set) var commentsByPath: [String: [ReviewComment]] = [:]
    @Published var commits: [Commit] = []
    /// Submitted review verdicts — approvals and change requests. These decide
    /// whether a PR is blocked, and the app used to show only the line notes
    /// underneath them.
    @Published private(set) var reviews: [PullRequestReview] = []
    @Published var isSubmittingReview = false
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
    @Published var isRefreshing = false
    /// Short transient result of the last refresh, shown in the overview.
    @Published var refreshNote: String?
    /// Why the checkout was left where it was, when a refresh declined to
    /// reset over uncommitted work.
    @Published var worktreeNote: String?
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

    /// Shows the open panel and switches to whatever is chosen.
    ///
    /// Lives here rather than in the sidebar button so the File menu and the
    /// button cannot drift into resetting different things.
    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a git repository to review pull requests from."
        // Beside the current one, which is usually where the next one is.
        panel.directoryURL = repoDir?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openRepository(at: url) }
    }

    /// Switches to another checkout.
    ///
    /// Everything derived from the old one goes before the new list lands: its
    /// PRs used to stay on screen and stay clickable while the new ones
    /// loaded, and opening one ran its number against the wrong checkout.
    func openRepository(at url: URL) async {
        repoDir = url   // its didSet clears the author filter and directory
        session = nil
        files = []
        comments = []
        commits = []
        commitFiles = []
        prs = []
        prSearch = ""
        prScope = .open
        prsTruncated = false
        repoSlug = nil
        currentHead = nil
        refreshNote = nil
        worktreeNote = nil
        errorBanner = nil

        guard Self.gitRoot(of: url) != nil else {
            // `gh` would fail with its own wording a second later; saying it
            // up front is the difference between a mistake and a mystery.
            errorBanner = "\(url.lastPathComponent) is not inside a git repository."
            return
        }
        await loadPRs()
    }

    /// The nearest ancestor holding a `.git` entry, or nil.
    ///
    /// `.git` is a directory in a clone and a file in a worktree, so this
    /// tests for either. `gh` runs from any subdirectory of a repository, and
    /// so should this.
    static func gitRoot(of url: URL) -> URL? {
        var dir = url.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { return nil }
            dir = parent
        }
    }

    func checkTools() async {
        let gh = await github.checkAvailability()
        let claude = (try? await processRunner.run("which", arguments: ["claude"], currentDirectory: nil))?.exitCode == 0
        toolCheck = (gh.ghInstalled, gh.ghAuthed, claude)
    }

    /// How many PRs one query returns. GitHub pages at 100; asking for more
    /// makes `gh` paginate, which is slow enough to notice on a repository
    /// with hundreds of open PRs. The search is the way past the page, not a
    /// bigger page.
    static let prPageSize = 100

    /// Guards against an older query landing after a newer one. Typing into
    /// the search field starts a query per keystroke-burst, and `gh` does not
    /// return them in order.
    private var prLoadToken = 0

    /// Appends without reordering: `knownAuthors` leads with the repository's
    /// contributors in GitHub's most-active-first order, which is the order a
    /// picker wants, and re-sorting alphabetically would throw that away.
    private func addAuthors(_ logins: [String]) {
        var seen = Set(knownAuthors)
        var added: [String] = []
        for login in logins where !login.isEmpty && seen.insert(login).inserted {
            added.append(login)
        }
        guard !added.isEmpty else { return }
        knownAuthors += added.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Keeps a hand-typed login in the picker, so it does not vanish when the
    /// search box is cleared. Contributors cover people with commits on the
    /// default branch; a first-time contributor appears nowhere until now.
    func rememberAuthor(_ login: String) {
        addAuthors([login])
    }

    /// Loads the repository's contributor list once per checkout. Failure is
    /// silent: the picker still works from the authors already seen, and its
    /// free-text field takes any login regardless.
    func loadAuthorDirectory() async {
        guard let repoDir, contributorsLoadedFor != repoDir, !isLoadingAuthors else { return }
        isLoadingAuthors = true
        defer { isLoadingAuthors = false }
        guard let logins = try? await github.fetchContributors(repoDir: repoDir) else { return }
        contributorsLoadedFor = repoDir
        // Contributors first, in GitHub's order, then whatever was already
        // known from the PRs on screen.
        var seen = Set<String>()
        let merged = (logins + knownAuthors).filter { !$0.isEmpty && seen.insert($0).inserted }
        knownAuthors = merged
    }

    func loadPRs(silent: Bool = false) async {
        guard let repoDir else { return }
        // Also the point a repo becomes known, which is what the login
        // lookup needs; at launch there may not be one yet.
        Task { await loadCurrentUser() }
        Task { _ = await nameWithOwner(repoDir: repoDir) }
        prLoadToken += 1
        let token = prLoadToken
        let scope = prScope
        let query = prSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !silent { isLoadingPRs = true }
        defer { if token == prLoadToken { isLoadingPRs = false } }
        do {
            let authors = prAuthors
            var found = try await github.listPRs(
                repoDir: repoDir, scope: scope,
                search: PRSearchQuery.full(query: query, authors: Array(authors)),
                limit: Self.prPageSize)
            let filledPage = found.count >= Self.prPageSize
            // Typing a number reaches that PR whatever its state or age — the
            // list it would otherwise have to appear in may be thousands long.
            if let number = PRSearchQuery.number(in: query) {
                if let i = found.firstIndex(where: { $0.number == number }) {
                    found.insert(found.remove(at: i), at: 0)
                } else if let exact = try? await github.fetchPR(repoDir: repoDir, number: number) {
                    found.insert(exact, at: 0)
                }
            }
            // A slower earlier query must not overwrite a newer one's results.
            guard token == prLoadToken else { return }
            prs = found
            prsTruncated = filledPage
            addAuthors(found.map(\.authorLogin) + Array(authors))
            errorBanner = nil
        } catch {
            guard token == prLoadToken else { return }
            // A search the user is still typing ("author:" on its own) is a
            // query error, not a broken app — and it clears as they finish.
            if silent { return }
            errorBanner = "Failed to list PRs: \(error.localizedDescription)"
        }
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

    private var cachedRemote: (dir: URL, value: String)?

    /// Which git remote corresponds to the repository `gh` is talking to.
    ///
    /// In a fork checkout `origin` is the fork and `gh` resolves the upstream,
    /// so fetching `pull/N/head` from `origin` fails — and every PR silently
    /// fell back to GitHub's three-line-context diff, with no head SHA and so
    /// no way to comment. Resolved once per checkout, like the slug.
    func remoteName(repoDir: URL) async -> String {
        if let cached = cachedRemote, cached.dir == repoDir { return cached.value }
        guard let slug = await nameWithOwner(repoDir: repoDir) else { return "origin" }
        let name = await github.remoteName(repoDir: repoDir, nameWithOwner: slug)
        cachedRemote = (repoDir, name)
        return name
    }

    /// Labels files the repository marks generated, and recovers the ones git
    /// refused to diff.
    ///
    /// `.gitattributes` can turn the diff driver off for a path (`-diff`).
    /// git then prints "Binary files a/x and b/x differ" for what is ordinary
    /// text, the parser sees a binary file, and the app showed a dead pane for
    /// a file the reader may well need. Asking again with `--text`, and only
    /// for the paths git itself says were suppressed, produces the real patch
    /// without risking a wall of bytes from a genuine binary.
    private func annotateGenerated(_ files: [FileDiff], worktree: URL,
                                   baseRef: String) async -> [FileDiff] {
        guard !files.isEmpty else { return files }
        var attributes: [String: GitFileAttributes] = [:]
        // Chunked so a PR touching thousands of files cannot overflow the
        // argument list.
        for chunk in stride(from: 0, to: files.count, by: 500).map({
            Array(files[$0..<min($0 + 500, files.count)])
        }) {
            guard let r = try? await processRunner.run(
                    "git",
                    arguments: ["check-attr", "-z"] + GitAttributes.queried + ["--"] + chunk.map(\.path),
                    currentDirectory: worktree),
                  r.exitCode == 0 else { continue }
            attributes.merge(GitAttributes.parse(r.stdout)) { _, new in new }
        }
        guard attributes.values.contains(where: { $0.isGenerated || $0.diffSuppressed }) else {
            return files
        }

        let suppressed = files.filter { attributes[$0.path]?.diffSuppressed == true && $0.hunks.isEmpty }
        var recovered: [String: FileDiff] = [:]
        if !suppressed.isEmpty,
           let r = try? await processRunner.run(
               "git",
               arguments: ["diff", "-U100000", "--text", "--merge-base", baseRef, "HEAD", "--"]
                   + suppressed.map(\.path),
               currentDirectory: worktree),
           r.exitCode == 0 {
            let text = r.stdout
            let parsed = await Task.detached(priority: .userInitiated) { DiffParser.parse(text) }.value
            for file in parsed { recovered[file.path] = file }
        }

        return files.map { file in
            let attrs = attributes[file.path] ?? GitFileAttributes()
            if let real = recovered[file.path], !real.hunks.isEmpty {
                return file.replacingHunks(real.hunks, kind: real.kind, isGenerated: true)
            }
            return file.marking(generated: attrs.isGenerated)
        }
    }

    /// IntelliJ-style full-file diff: check the PR out into its worktree and
    /// diff against the base branch with unlimited context, so every line of
    /// each changed file renders (changes highlighted inline). Falls back to
    /// `gh pr diff`'s 3-line-context hunks when any step fails.
    /// The diff and the commit it was read from, so callers cannot pair one
    /// PR's files with another's head.
    private struct FullDiff { let files: [FileDiff]; let head: String }

    /// - Parameter force: fetch even when the checkout already looks current.
    ///   An explicit refresh must go to the network; opening a PR need not.
    private func fetchFullContextDiff(repoDir: URL, pr: PullRequest,
                                      force: Bool = false) async -> FullDiff? {
        guard let base = pr.baseRefName else { return nil }
        do {
            let remote = await remoteName(repoDir: repoDir)
            let worktrees = WorktreeManager(
                runner: processRunner,
                baseDir: Self.appSupportDir.appendingPathComponent("worktrees"))

            // The checkout is already at the commit GitHub reported for this
            // PR, so there is nothing to fetch.
            //
            // Re-fetching unconditionally is what stopped a re-opened PR
            // showing yesterday's commits, but a `git fetch` against a large
            // repository costs a couple of seconds even when it transfers
            // nothing — it is the handshake and the ref advertisement, so
            // `ls-remote` is no cheaper. This compares against the same list
            // payload the row just clicked was drawn from, which the list
            // re-fetches every minute and whenever the app is activated.
            if !force, let expected = pr.headRefOid, !expected.isEmpty,
               let local = await worktrees.currentHead(repoName: repoName, prNumber: pr.number),
               local == expected {
                let wt = worktrees.worktreeURL(repoName: repoName, prNumber: pr.number)
                guard let baseRef = await resolveBase(pr: pr, base: base,
                                                      remote: remote, worktree: wt),
                      let files = await parseDiff(worktree: wt, baseRef: baseRef,
                                                  remote: remote) else { return nil }
                return FullDiff(files: files, head: local)
            }

            let head: String
            do {
                head = try await worktrees.refreshWorktree(
                    cloneDir: repoDir, repoName: repoName, prNumber: pr.number, remote: remote)
            } catch WorktreeError.localChanges {
                // An applied fix is sitting in the checkout. Show the PR as it
                // stands rather than resetting over work the user was told to
                // review, and say so instead of failing silently.
                guard let stale = await worktrees.currentHead(repoName: repoName,
                                                              prNumber: pr.number) else { return nil }
                worktreeNote = WorktreeError.localChanges.errorDescription
                head = stale
            }
            let wt = worktrees.worktreeURL(repoName: repoName, prNumber: pr.number)
            guard let baseRef = await resolveBase(pr: pr, base: base, remote: remote, worktree: wt),
                  let files = await parseDiff(worktree: wt, baseRef: baseRef, remote: remote)
            else { return nil }
            return FullDiff(files: files, head: head)
        } catch { return nil }
    }

    private func parseDiff(worktree: URL, baseRef: String, remote: String) async -> [FileDiff]? {
        guard let diff = try? await processRunner.run(
                "git", arguments: ["diff", "-U100000", "--merge-base", baseRef, "HEAD"],
                currentDirectory: worktree),
              diff.exitCode == 0, !diff.stdout.isEmpty else { return nil }
        // Parsing a multi-megabyte full-context diff on the main actor froze
        // the UI for the whole open.
        let text = diff.stdout
        let parsed = await Task.detached(priority: .userInitiated) {
            DiffParser.parse(text)
        }.value
        guard !parsed.isEmpty else { return nil }
        return await annotateGenerated(parsed, worktree: worktree, baseRef: baseRef)
    }

    /// What to diff against.
    ///
    /// The base branch tip is wrong for a PR that has already been merged: the
    /// branch now contains the PR, so the merge-base is the head itself and
    /// the diff comes out empty — which is what sent every merged PR down the
    /// three-line-context fallback. GitHub reports the base commit the PR was
    /// opened against, so use that when it is known and fall back to the
    /// branch for sessions saved before the field existed.
    private func resolveBase(pr: PullRequest, base: String,
                             remote: String, worktree: URL) async -> String? {
        func have(_ ref: String) async -> Bool {
            let r = try? await processRunner.run(
                "git", arguments: ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"],
                currentDirectory: worktree)
            return r?.exitCode == 0
        }

        if let oid = pr.baseRefOid, !oid.isEmpty {
            if await have(oid) { return oid }
            // GitHub serves arbitrary reachable SHAs, so the base commit can be
            // fetched directly even after the branch has moved past it.
            if let r = try? await processRunner.run("git", arguments: ["fetch", remote, oid],
                                                    currentDirectory: worktree),
               r.exitCode == 0 {
                return oid
            }
        }

        let branchRef = "\(remote)/\(base)"
        // Fetch the branch only when its ref is missing; when it exists, refresh
        // it in the background instead of on the open's critical path (a
        // slightly stale merge-base is fine for one open).
        if await have(branchRef) {
            let runner = processRunner
            Task.detached(priority: .utility) {
                _ = try? await runner.run("git", arguments: ["fetch", remote, base],
                                          currentDirectory: worktree)
            }
            return branchRef
        }
        guard let fetch = try? await processRunner.run("git", arguments: ["fetch", remote, base],
                                                       currentDirectory: worktree),
              fetch.exitCode == 0 else { return nil }
        return branchRef
    }

    func openPR(_ pr: PullRequest) async {
        guard let repoDir, openingPR == nil else { return }
        openingPR = pr.number
        openingPRNumber = pr.number
        isLoadingDetails = true
        defer { openingPR = nil; openingPRNumber = nil; isLoadingDetails = false }
        // The previous PR's comments and commits must not linger while this
        // one loads — they would be attributed to the wrong PR on screen. The
        // same goes for the last refresh's note, which named a commit on a
        // different PR.
        comments = []
        commits = []
        reviews = []
        refreshNote = nil
        worktreeNote = nil
        currentHead = nil
        do {
            // Comments (REST + GraphQL threads) and commits load concurrently
            // with the diff instead of after it.
            async let commentsTask = loadComments(repoDir: repoDir, number: pr.number)
            async let commitsTask = loadCommits(repoDir: repoDir, number: pr.number)
            async let reviewsTask = loadReviews(repoDir: repoDir, number: pr.number)
            let full = await fetchFullContextDiff(repoDir: repoDir, pr: pr)
            if let full {
                files = full.files
            } else {
                files = try await github.fetchDiff(repoDir: repoDir, number: pr.number)
            }
            // The worktree the diff was read from is already at the PR head;
            // asking git for it again was a second subprocess for a value we
            // had, and it ran after the comments so commenting was blocked
            // until they landed.
            currentHead = full?.head

            // Show the PR as soon as its diff exists. Waiting for the `gh`
            // round-trips first left the window unchanged for well over a
            // second after the click, with the diff already in hand.
            let data = sessionStore.load(repo: repoName, prNumber: pr.number)
                ?? SessionData(pr: pr, repoDir: repoDir.path, viewedFiles: [], chat: [], findings: [])
            session = ReviewSession(data: data)
            // Land on the PR overview; the user picks a file from the tree.
            session?.selectedFile = nil
            errorBanner = nil
            openingPRNumber = nil

            comments = await commentsTask
            commits = await commitsTask
            reviews = await reviewsTask
            isLoadingDetails = false
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
    /// Opens the Explain pane, running the walkthrough if there isn't one.
    ///
    /// `force` re-runs against the current head; without it an existing
    /// explanation is shown as-is, so returning to the pane is instant and
    /// does not spend an agent run.
    func explainDiff(force: Bool = false) async {
        guard let session else { return }
        session.pane = .explain
        closeCommit()
        guard force || session.data.explanation == nil else { return }
        guard session.agentState.canStart else { return }
        await agent.runExplain()
    }

    /// Opens the Review pane, running the review if there isn't one.
    func review(force: Bool = false) async {
        guard let session else { return }
        session.pane = .review
        closeCommit()
        guard force || session.data.reviewStamp == nil else { return }
        guard session.agentState.canStart else { return }
        await agent.runReview()
    }

    /// Triage state lives on the finding and is saved with the session, so a
    /// dismissal survives closing the PR.
    func setFindingDismissed(_ finding: Finding, _ dismissed: Bool) {
        guard let session else { return }
        guard let i = session.data.findings.firstIndex(where: { $0.id == finding.id }) else { return }
        session.data.findings[i].dismissed = dismissed
        sessionStore.saveInBackground(session.data)
    }

    func showOverview() {
        session?.selectedFile = nil
        session?.pane = .diff
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
            session.pane = .commits
            await openCommit(known)
            return
        }

        let worktree = Self.appSupportDir
            .appendingPathComponent("worktrees/\(repoName)-pr\(session.data.pr.number)")
        // %x1f separates fields; the subject and body can contain anything.
        let format = "%H%x1f%an%x1f%aI%x1f%s%x1f%b"
        if let r = try? await processRunner.run(
                // `--` so a revision can never be read as an option, belt to
                // the hex validation in CommitReference.sha(from:)'s braces.
                "git", arguments: ["show", "-s", "--format=\(format)", sha, "--"],
                currentDirectory: worktree),
           r.exitCode == 0 {
            let parts = r.stdout.components(separatedBy: "\u{1f}")
            if parts.count >= 4 {
                let resolved = Commit(sha: parts[0], subject: parts[3],
                                      body: parts.count > 4 ? parts[4] : "",
                                      author: parts[1], date: parts[2])
                session.pane = .commits
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

    /// Verdicts only. An empty-bodied "COMMENTED" review is the envelope
    /// GitHub wraps around inline notes, and those are shown on their own.
    private func loadReviews(repoDir: URL, number: Int) async -> [PullRequestReview] {
        let loaded = (try? await github.fetchReviews(repoDir: repoDir, number: number)) ?? []
        return loaded.filter(\.isMeaningful)
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

    /// Applies a change GitHub has already accepted to the local list.
    ///
    /// Every comment action used to end by re-downloading the PR's whole
    /// comment list — `gh api --paginate` plus a GraphQL query, two processes —
    /// and republishing it, which re-groups every thread and re-renders the
    /// sidebar and the open diff. Resolving three threads in a row was six
    /// round trips to say three booleans.
    private func applyLocally(_ change: (inout [ReviewComment]) -> Void) {
        var updated = comments
        change(&updated)
        comments = updated
    }

    func edit(_ comment: ReviewComment, body: String) async {
        guard let repoDir, let session else { return }
        do {
            let updated = try await github.updateComment(
                repoDir: repoDir, commentID: comment.id, body: body)
            if let updated {
                applyLocally { list in
                    guard let i = list.firstIndex(where: { $0.id == updated.id }) else { return }
                    // GitHub's reply does not carry the thread state, which was
                    // merged in from GraphQL; keep what we already know.
                    var merged = updated
                    merged.threadID = list[i].threadID
                    merged.resolved = list[i].resolved
                    list[i] = merged
                }
            } else {
                comments = await loadComments(repoDir: repoDir, number: session.data.pr.number)
            }
            errorBanner = nil
        } catch {
            errorBanner = "Failed to edit comment: \(error.localizedDescription)"
        }
    }

    func delete(_ comment: ReviewComment) async {
        guard let repoDir else { return }
        do {
            try await github.deleteComment(repoDir: repoDir, commentID: comment.id)
            applyLocally { $0.removeAll { $0.id == comment.id } }
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
            let created = try await github.createComment(
                repoDir: repoDir, number: session.data.pr.number, commitID: head,
                path: path, line: endLine,
                startLine: startLine < endLine ? startLine : nil, body: body)
            if let created {
                // A brand-new thread has no GraphQL id yet, so it cannot be
                // resolved until the next full load — which is fine: a thread
                // you just opened is not one you resolve.
                applyLocally { $0.append(created) }
            } else {
                comments = await loadComments(repoDir: repoDir, number: session.data.pr.number)
            }
            errorBanner = nil
        } catch {
            // The usual cause is commenting on a line outside the diff, which
            // GitHub refuses; say so rather than showing a bare API error.
            errorBanner = "Failed to add comment: \(error.localizedDescription)"
        }
    }

    // MARK: - Staged review

    /// Stages a line note instead of posting it.
    ///
    /// Posting each note the moment it is written — which is what this app did
    /// — sends the author a separate notification per note and leaves a
    /// half-finished review behind if one call fails. GitHub's own model is a
    /// pending review: write the notes, then submit them together with a
    /// verdict.
    func stageComment(path: String, startLine: Int, endLine: Int, body: String) {
        guard let session else { return }
        session.data.draftComments.append(
            DraftComment(path: path, line: endLine,
                         startLine: startLine < endLine ? startLine : nil, body: body))
        saveSession()
    }

    func removeDraft(_ draft: DraftComment) {
        guard let session else { return }
        session.data.draftComments.removeAll { $0.id == draft.id }
        saveSession()
    }

    func updateDraft(_ draft: DraftComment, body: String) {
        guard let session,
              let i = session.data.draftComments.firstIndex(where: { $0.id == draft.id })
        else { return }
        session.data.draftComments[i].body = body
        saveSession()
    }

    func setDraftReviewBody(_ body: String) {
        guard let session else { return }
        session.data.draftReviewBody = body
        saveSession()
    }

    private func saveSession() {
        guard let session else { return }
        sessionStore.saveInBackground(session.data) { [weak self] error in
            self?.errorBanner = "Failed to save session: \(error.localizedDescription)"
        }
    }

    /// Sends every staged note and the verdict as one review.
    func submitReview(_ verdict: ReviewVerdict) async {
        guard let repoDir, let session, !isSubmittingReview else { return }
        guard let head = currentHead, !head.isEmpty else {
            errorBanner = "Cannot submit yet: still resolving the PR's head commit."
            return
        }
        let drafts = session.data.draftComments
        let body = session.data.draftReviewBody
        guard !drafts.isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || verdict != .comment else {
            errorBanner = "Nothing to submit — write a note or pick a verdict."
            return
        }
        isSubmittingReview = true
        defer { isSubmittingReview = false }
        do {
            try await github.submitReview(repoDir: repoDir, number: session.data.pr.number,
                                          commitID: head, verdict: verdict,
                                          body: body, comments: drafts)
            // Cleared only after GitHub accepted it: a failed submit must
            // leave the afternoon's notes exactly where they were.
            session.data.draftComments = []
            session.data.draftReviewBody = ""
            saveSession()
            comments = await loadComments(repoDir: repoDir, number: session.data.pr.number)
            reviews = await loadReviews(repoDir: repoDir, number: session.data.pr.number)
            refreshNote = "Review submitted"
            errorBanner = nil
        } catch {
            errorBanner = "Failed to submit review: \(error.localizedDescription)"
        }
    }

    func reply(to comment: ReviewComment, body: String) async {
        guard let repoDir, let session else { return }
        do {
            let posted = try await github.replyToComment(
                repoDir: repoDir, number: session.data.pr.number,
                commentID: comment.id, body: body)
            if var posted {
                // Same thread as the comment replied to, so it inherits its
                // thread id and resolved state.
                posted.threadID = comment.threadID
                posted.resolved = comment.resolved
                applyLocally { $0.append(posted) }
            } else {
                comments = await loadComments(repoDir: repoDir, number: session.data.pr.number)
            }
            errorBanner = nil
        } catch {
            errorBanner = "Failed to reply: \(error.localizedDescription)"
        }
    }

    func resolve(_ comment: ReviewComment) async {
        guard let repoDir, let threadID = comment.threadID else { return }
        do {
            try await github.resolveThread(repoDir: repoDir, threadID: threadID)
            applyLocally { list in
                for i in list.indices where list[i].threadID == threadID {
                    list[i].resolved = true
                }
            }
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
            let previousHead = currentHead
            worktreeNote = nil
            async let commentsTask = loadComments(repoDir: repoDir, number: pr.number)
            async let commitsTask = loadCommits(repoDir: repoDir, number: pr.number)
            async let reviewsTask = loadReviews(repoDir: repoDir, number: pr.number)
            // Re-fetching the head is part of building the full-context diff,
            // so refreshing is the same work as opening — doing it here too
            // fetched the same ref twice.
            let full = await fetchFullContextDiff(repoDir: repoDir, pr: pr, force: true)
            if let full {
                files = full.files
            } else {
                files = try await github.fetchDiff(repoDir: repoDir, number: pr.number)
            }
            comments = await commentsTask
            commits = await commitsTask
            reviews = await reviewsTask
            let head = full?.head ?? currentHead
            currentHead = head
            // Keep the open file if it still exists in the refreshed diff.
            if let selected = session.selectedFile,
               !files.contains(where: { $0.path == selected }) {
                session.selectedFile = nil
            }
            refreshNote = (previousHead == nil || previousHead == head)
                ? "Already up to date"
                : "Updated to \(String((head ?? "").prefix(7)))"
            errorBanner = nil
        } catch {
            errorBanner = "Failed to refresh PR #\(pr.number): \(error.localizedDescription)"
        }
    }

    func markViewed(_ path: String, viewed: Bool) {
        guard let session else { return }
        if viewed { session.data.viewedFiles.insert(path) } else { session.data.viewedFiles.remove(path) }
        // Off the main actor: a tick encodes the whole session and writes it
        // atomically, and the checkbox should not wait for the disk.
        sessionStore.saveInBackground(session.data) { [weak self] error in
            self?.errorBanner = "Failed to save session: \(error.localizedDescription)"
        }
    }

}
