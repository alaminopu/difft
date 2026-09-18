import Foundation
import DifftCore

public struct PullRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let body: String
    public let headRefName: String
    /// Branch the PR merges into; optional so sessions saved before this
    /// field existed still decode.
    public let baseRefName: String?
    /// The base branch's commit at the time GitHub was asked.
    ///
    /// Needed because `<remote>/<branch>` is the wrong base for a PR that has
    /// already been merged: the branch now contains the PR, so the merge-base
    /// is the head itself and the diff comes out empty.
    public let baseRefOid: String?
    /// The PR's head commit, as GitHub reported it when the list was fetched.
    ///
    /// Lets opening a PR skip the network entirely when the checkout is
    /// already at that commit — which is the common case, and a `git fetch`
    /// against a large repository costs a couple of seconds even when it
    /// transfers nothing.
    public let headRefOid: String?
    public let authorLogin: String
    /// "OPEN", "CLOSED" or "MERGED". Optional for the same reason as
    /// `baseRefName`: sessions written before the list could show anything but
    /// open PRs have to keep decoding.
    public let state: String?
    public let isDraft: Bool?
    /// ISO8601. Shown in the list the way GitHub and IntelliJ show it, so a
    /// long-lived PR is recognisable without opening it.
    public let createdAt: String?

    public init(number: Int, title: String, body: String, headRefName: String,
                baseRefName: String? = nil, baseRefOid: String? = nil,
                headRefOid: String? = nil, authorLogin: String,
                state: String? = nil, isDraft: Bool? = nil, createdAt: String? = nil) {
        self.number = number; self.title = title; self.body = body
        self.headRefName = headRefName; self.baseRefName = baseRefName
        self.baseRefOid = baseRefOid
        self.headRefOid = headRefOid
        self.authorLogin = authorLogin
        self.state = state; self.isDraft = isDraft; self.createdAt = createdAt
    }

    /// Uppercase state, or "OPEN" for a PR fetched before the field existed.
    public var stateLabel: String { (state ?? "OPEN").uppercased() }
    public var isOpen: Bool { stateLabel == "OPEN" }
}

/// What the user typed into the pull-request search field.
public enum PRSearchQuery {
    /// A PR number the user typed: "6022", "#6022", or a GitHub URL ending in
    /// one. nil when the query is words rather than a number.
    public static func number(in query: String) -> Int? {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pull = text.range(of: "/pull/", options: .backwards) {
            text = String(text[pull.upperBound...])
        }
        if text.hasPrefix("#") { text.removeFirst() }
        // Trailing slash or fragment on a pasted URL.
        while let last = text.last, last == "/" { text.removeLast() }
        guard !text.isEmpty, text.count <= 12,
              text.allSatisfy(\.isNumber), let n = Int(text), n > 0 else { return nil }
        return n
    }

    /// A bare number is not handed to GitHub's text search — it would match
    /// every PR whose body happens to mention that number. It is looked up
    /// directly instead, and pinned to the top of the normal list.
    public static func terms(in query: String) -> String {
        number(in: query) == nil ? query : ""
    }

    /// The whole query GitHub is given: what the user typed, narrowed to the
    /// authors they ticked.
    ///
    /// Several `author:` qualifiers side by side are ANDed, and no PR has two
    /// authors — that combination always returns nothing. They have to be an
    /// explicit OR, parenthesised so the text terms still apply to all of it.
    public static func full(query: String, authors: [String]) -> String {
        var parts: [String] = []
        let text = terms(in: query).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(text) }
        let logins = Set(authors.map { $0.trimmingCharacters(in: .whitespaces) })
            .filter { !$0.isEmpty }.sorted()
        if logins.count == 1 {
            parts.append("author:\(logins[0])")
        } else if logins.count > 1 {
            parts.append("(" + logins.map { "author:\($0)" }.joined(separator: " OR ") + ")")
        }
        return parts.joined(separator: " ")
    }
}

/// Which PRs the list asks GitHub for.
///
/// Open-only was the whole world until the list could search; searching for a
/// number you remember usually means a PR that has already been merged.
///
/// Draft is not one of GitHub's states — it is a flag on an open pull request
/// — so "Open" covers both, the way GitHub's own Open tab and `gh pr list` do,
/// and the two draft scopes narrow it with a search qualifier.
public enum PRScope: String, CaseIterable, Identifiable, Sendable {
    case open, ready, draft, closed, merged, all
    public var id: Self { self }

    /// What `gh pr list --state` is given.
    var ghState: String {
        switch self {
        case .ready, .draft: return "open"
        default: return rawValue
        }
    }

    /// Extra search terms, ANDed with whatever the user typed.
    var qualifier: String {
        switch self {
        case .draft: return "is:draft"
        case .ready: return "-is:draft"
        default: return ""
        }
    }

    /// "Open" on its own is ambiguous once drafts can be filtered separately:
    /// it reads as the opposite of closed *and* as the opposite of draft. The
    /// three open scopes say which they are.
    public var label: String {
        switch self {
        case .open: return "All open"
        case .ready: return "Ready for review"
        case .draft: return "Draft"
        case .closed: return "Closed"
        case .merged: return "Merged"
        case .all: return "All"
        }
    }

    /// Scopes that narrow the open pull requests, versus the states.
    public static let openScopes: [PRScope] = [.open, .ready, .draft]
    public static let closedScopes: [PRScope] = [.closed, .merged, .all]

    /// Reads as a sentence, which "No ready for review PRs" does not.
    public var emptyDescription: String {
        switch self {
        case .open: return "No open pull requests."
        case .ready: return "Every open pull request is still a draft."
        case .draft: return "No open pull request is a draft."

        case .closed: return "No closed pull requests."
        case .merged: return "No merged pull requests."
        case .all: return "No pull requests."
        }
    }
}

/// One inline review comment on a PR, anchored to a file and line.
public struct ReviewComment: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let author: String
    public let body: String
    public let path: String
    /// Line in the file the comment anchors to (nil for outdated comments).
    public let line: Int?
    /// "LEFT" anchors to the old file's numbering, "RIGHT" to the new one.
    public let side: String?
    public let createdAt: String
    public let inReplyToID: Int?
    /// The few lines of diff GitHub anchors the comment to. Present on the
    /// REST payload; kept so the comments list can show context without
    /// opening the file.
    public let diffHunk: String?
    /// GraphQL review-thread node id (needed to resolve) and its state,
    /// merged in after the REST fetch.
    public var threadID: String?
    public var resolved: Bool = false
    public init(id: Int, author: String, body: String, path: String, line: Int?,
                side: String?, createdAt: String, inReplyToID: Int?,
                diffHunk: String? = nil,
                threadID: String? = nil, resolved: Bool = false) {
        self.id = id; self.author = author; self.body = body; self.path = path
        self.line = line; self.side = side; self.createdAt = createdAt
        self.inReplyToID = inReplyToID; self.diffHunk = diffHunk
        self.threadID = threadID; self.resolved = resolved
    }
}


/// A submitted review: the verdict, not the line notes underneath it.
///
/// These live at `pulls/{n}/reviews` and are what decides whether a PR is
/// blocked. The app read only the inline comments, so "someone requested
/// changes" was the one thing about a pull request it could not tell you.
public struct PullRequestReview: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let author: String
    /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, PENDING.
    public let state: String
    public let body: String
    public let submittedAt: String?

    public init(id: Int, author: String, state: String, body: String, submittedAt: String?) {
        self.id = id; self.author = author; self.state = state
        self.body = body; self.submittedAt = submittedAt
    }

    public var isApproval: Bool { state == "APPROVED" }
    public var isBlocking: Bool { state == "CHANGES_REQUESTED" }
    /// A review with no verdict and no body is the envelope GitHub creates
    /// around inline comments — the comments themselves are shown separately,
    /// so an empty envelope is noise.
    public var isMeaningful: Bool {
        isApproval || isBlocking || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var label: String {
        switch state {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "requested changes"
        case "DISMISSED": return "review dismissed"
        default: return "commented"
        }
    }
}

/// Where a pull request stands once every reviewer's latest word is counted.
public struct ReviewTally: Equatable, Sendable {
    public var approvals: Int
    public var blocking: Int
    public init(approvals: Int = 0, blocking: Int = 0) {
        self.approvals = approvals; self.blocking = blocking
    }

    /// Only the newest verdict from each reviewer counts, which is GitHub's
    /// own rule and the only one that gives the right answer: someone who
    /// requests changes and later approves has approved. Counting every review
    /// ever submitted reports the PR as blocked forever.
    ///
    /// A plain comment leaves a reviewer's standing untouched, and a dismissed
    /// review removes it — that is what dismissing is for.
    ///
    /// - Parameter reviews: oldest first, as GitHub returns them.
    public static func of(_ reviews: [PullRequestReview]) -> ReviewTally {
        var standing: [String: String] = [:]
        for review in reviews {
            switch review.state {
            case "APPROVED", "CHANGES_REQUESTED":
                standing[review.author] = review.state
            case "DISMISSED":
                standing[review.author] = nil
            default:
                break
            }
        }
        return ReviewTally(
            approvals: standing.values.count { $0 == "APPROVED" },
            blocking: standing.values.count { $0 == "CHANGES_REQUESTED" })
    }
}

/// What submitting a review says about the pull request.
public enum ReviewVerdict: String, CaseIterable, Identifiable, Sendable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    public var id: Self { self }
    public var label: String {
        switch self {
        case .comment: return "Comment"
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        }
    }
    public var detail: String {
        switch self {
        case .comment: return "Leave notes without a verdict."
        case .approve: return "Sign off on these changes."
        case .requestChanges: return "Block the PR until these are addressed."
        }
    }
}

/// One line note staged locally, not yet sent to GitHub.
public struct DraftComment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let line: Int
    /// Start of a multi-line anchor; nil for a single line.
    public let startLine: Int?
    public var body: String
    public let createdAt: Date

    public init(id: UUID = UUID(), path: String, line: Int, startLine: Int? = nil,
                body: String, createdAt: Date = Date()) {
        self.id = id; self.path = path; self.line = line
        self.startLine = startLine; self.body = body; self.createdAt = createdAt
    }
}

/// One commit on a PR. GitHub's own commits tab shows message, author, date
/// and sha with no per-commit stats, and the list endpoint carries none
/// either, so neither does this.
public struct Commit: Codable, Equatable, Identifiable, Sendable {
    public let sha: String
    /// First line of the commit message.
    public let subject: String
    /// Everything after the first line; empty when the message is one line.
    public let body: String
    public let author: String
    /// ISO8601, the date the commit was authored.
    public let date: String

    public init(sha: String, subject: String, body: String, author: String, date: String) {
        self.sha = sha; self.subject = subject; self.body = body
        self.author = author; self.date = date
    }

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var hasBody: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A comment body split for rendering: prose segments (inline markdown) and
/// fenced code blocks.
public enum CommentBodySegment: Equatable, Sendable {
    case text(String)
    case code(String)

    public static func parse(_ body: String) -> [CommentBodySegment] {
        var segments: [CommentBodySegment] = []
        var text: [String] = []
        var code: [String] = []
        var inCode = false
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    segments.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    let t = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { segments.append(.text(t)) }
                    text = []
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line) } else { text.append(line) }
        }
        if inCode, !code.isEmpty { segments.append(.code(code.joined(separator: "\n"))) }
        let t = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { segments.append(.text(t)) }
        return segments
    }
}

public enum GitHubServiceError: Error, Equatable, LocalizedError {
    case commandFailed(String)

    /// Without `LocalizedError`, `error.localizedDescription` throws away the
    /// stderr this carries and every banner in the app read "The operation
    /// couldn't be completed. (DifftServices.GitHubServiceError error 0.)" —
    /// hiding the one thing worth showing, which is what GitHub said.
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "gh command failed" }
            // `gh` writes multi-line errors with the useful sentence last.
            let lines = trimmed.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return lines.suffix(2).joined(separator: " ")
        }
    }
}

public final class GitHubService: Sendable {
    private let runner: ProcessRunning
    public init(runner: ProcessRunning = DefaultProcessRunner()) { self.runner = runner }

    /// Fields both the list and the single-PR lookup ask for, so the two
    /// cannot drift into returning differently-populated PullRequests.
    static let prFields = "number,title,body,headRefName,baseRefName,baseRefOid,headRefOid,author,state,isDraft,createdAt"

    private struct RawPR: Codable {
        struct Author: Codable { let login: String? }
        let number: Int; let title: String; let body: String; let headRefName: String
        let baseRefName: String?; let baseRefOid: String?; let headRefOid: String?
        let author: Author?
        let state: String?; let isDraft: Bool?; let createdAt: String?

        var pullRequest: PullRequest {
            PullRequest(number: number, title: title, body: body, headRefName: headRefName,
                        baseRefName: baseRefName, baseRefOid: baseRefOid, headRefOid: headRefOid,
                        // A PR opened by a deleted account has no login, and
                        // decoding must not fail over an empty byline.
                        authorLogin: author?.login ?? "",
                        state: state, isDraft: isDraft, createdAt: createdAt)
        }
    }

    /// Lists pull requests, optionally narrowed by GitHub's own search syntax.
    ///
    /// `search` is handed to GitHub rather than applied here: on a repository
    /// with hundreds of PRs, filtering a locally-held page only ever searches
    /// that page. Everything the user types — `payments`, `author:someone`,
    /// `is:draft` — is a server-side query over the whole repository.
    public func listPRs(repoDir: URL, scope: PRScope = .open,
                        search: String = "", limit: Int = 100) async throws -> [PullRequest] {
        var args = ["pr", "list", "--state", scope.ghState,
                    "--limit", String(max(1, limit)), "--json", Self.prFields]
        let query = [search, scope.qualifier]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !query.isEmpty { args += ["--search", query] }
        let r = try await runner.run("gh", arguments: args, currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        return try JSONDecoder().decode([RawPR].self, from: Data(r.stdout.utf8)).map(\.pullRequest)
    }

    /// One PR by number, whatever its state.
    ///
    /// Typing a number you remember is the most direct way to reach a PR, and
    /// it has to work for a PR that was merged months ago and appears in no
    /// list the app would otherwise fetch.
    public func fetchPR(repoDir: URL, number: Int) async throws -> PullRequest {
        let r = try await runner.run(
            "gh", arguments: ["pr", "view", String(number), "--json", Self.prFields],
            currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        return try JSONDecoder().decode(RawPR.self, from: Data(r.stdout.utf8)).pullRequest
    }

    public func fetchDiff(repoDir: URL, number: Int) async throws -> [FileDiff] {
        let r = try await runner.run("gh", arguments: ["pr", "diff", String(number)], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        return DiffParser.parse(r.stdout)
    }

    public func fetchComments(repoDir: URL, number: Int) async throws -> [ReviewComment] {
        let r = try await runner.run("gh", arguments: [
            "api", "repos/{owner}/{repo}/pulls/\(number)/comments", "--paginate",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        struct Raw: Codable {
            struct User: Codable { let login: String }
            let id: Int; let user: User; let body: String; let path: String
            let line: Int?; let side: String?; let created_at: String
            let in_reply_to_id: Int?; let diff_hunk: String?
        }
        let raws = try JSONDecoder().decode([Raw].self, from: Data(r.stdout.utf8))
        return raws.map { ReviewComment(id: $0.id, author: $0.user.login, body: $0.body,
                                        path: $0.path, line: $0.line, side: $0.side,
                                        createdAt: $0.created_at, inReplyToID: $0.in_reply_to_id,
                                        diffHunk: $0.diff_hunk) }
            .sorted { $0.createdAt < $1.createdAt }
    }


    public func fetchCommits(repoDir: URL, number: Int) async throws -> [Commit] {
        let r = try await runner.run("gh", arguments: [
            "pr", "view", String(number), "--json", "commits",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        struct Raw: Codable {
            struct Wrapper: Codable { let commits: [C] }
            struct C: Codable {
                struct Author: Codable { let login: String?; let name: String? }
                let oid: String
                let messageHeadline: String
                let messageBody: String?
                let authoredDate: String
                let authors: [Author]?
            }
        }
        let wrapper = try JSONDecoder().decode(Raw.Wrapper.self, from: Data(r.stdout.utf8))
        return wrapper.commits.map { c in
            // A commit authored outside GitHub has no login, only the name
            // from the git trailer; showing nothing there would be worse.
            let who = c.authors?.first.flatMap { $0.login ?? $0.name } ?? ""
            return Commit(sha: c.oid, subject: c.messageHeadline,
                          body: c.messageBody ?? "", author: who, date: c.authoredDate)
        }
    }

    /// "owner/name" for the checkout. Its own `gh` invocation costs about half
    /// a second, and it cannot change while a repo is open, so callers are
    /// expected to fetch it once and hold it.
    public func nameWithOwner(repoDir: URL) async throws -> String {
        let who = try await runner.run("gh", arguments: ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], currentDirectory: repoDir)
        guard who.exitCode == 0 else { throw GitHubServiceError.commandFailed(who.stderr) }
        return who.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Maps each comment's databaseId to its review thread (GraphQL id +
    /// resolved flag) so the UI can offer resolve and show state.
    public func fetchThreadInfo(repoDir: URL, number: Int,
                                nameWithOwner: String) async throws -> [Int: (threadID: String, resolved: Bool)] {
        let parts = nameWithOwner.split(separator: "/")
        guard parts.count == 2 else { throw GitHubServiceError.commandFailed("bad nameWithOwner") }
        let query = """
        query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{id isResolved comments(first:100){nodes{databaseId}}}}}}}
        """
        let r = try await runner.run("gh", arguments: [
            "api", "graphql", "-f", "query=\(query)",
            "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])", "-F", "number=\(number)",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        struct Resp: Codable {
            struct D: Codable { let repository: Repo }
            struct Repo: Codable { let pullRequest: PR }
            struct PR: Codable { let reviewThreads: Threads }
            struct Threads: Codable { let nodes: [Thread] }
            struct Thread: Codable { let id: String; let isResolved: Bool; let comments: Comments }
            struct Comments: Codable { let nodes: [C] }
            struct C: Codable { let databaseId: Int? }
            let data: D
        }
        let resp = try JSONDecoder().decode(Resp.self, from: Data(r.stdout.utf8))
        var map: [Int: (String, Bool)] = [:]
        for thread in resp.data.repository.pullRequest.reviewThreads.nodes {
            for c in thread.comments.nodes {
                if let dbid = c.databaseId { map[dbid] = (thread.id, thread.isResolved) }
            }
        }
        return map
    }

    /// GitHub returns the comment it just created or changed. Decoding it lets
    /// the caller update its own list instead of re-downloading every comment
    /// on the PR — which was two `gh` processes per reply, edit or resolve.
    private struct RawComment: Codable {
        struct User: Codable { let login: String }
        let id: Int; let user: User; let body: String; let path: String
        let line: Int?; let side: String?; let created_at: String
        let in_reply_to_id: Int?; let diff_hunk: String?

        var comment: ReviewComment {
            ReviewComment(id: id, author: user.login, body: body, path: path, line: line,
                          side: side, createdAt: created_at, inReplyToID: in_reply_to_id,
                          diffHunk: diff_hunk)
        }
    }

    @discardableResult
    /// Submitted reviews, oldest first.
    public func fetchReviews(repoDir: URL, number: Int) async throws -> [PullRequestReview] {
        let r = try await runner.run("gh", arguments: [
            "api", "repos/{owner}/{repo}/pulls/\(number)/reviews?per_page=100", "--paginate",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        struct Raw: Codable {
            struct User: Codable { let login: String? }
            let id: Int; let user: User?; let state: String?
            let body: String?; let submitted_at: String?
        }
        return try JSONDecoder().decode([Raw].self, from: Data(r.stdout.utf8)).map {
            PullRequestReview(id: $0.id, author: $0.user?.login ?? "",
                              state: $0.state ?? "COMMENTED", body: $0.body ?? "",
                              submittedAt: $0.submitted_at)
        }
    }

    /// Submits one review carrying every staged note at once.
    ///
    /// Posting notes one at a time — which is what the app did, and what the
    /// `pulls/{n}/comments` endpoint does — sends the author a separate
    /// notification per note and leaves a half-posted review behind if one
    /// call fails. `POST /pulls/{n}/reviews` takes the whole batch and the
    /// verdict together: one notification, and all of it or none.
    public func submitReview(repoDir: URL, number: Int, commitID: String,
                             verdict: ReviewVerdict, body: String,
                             comments: [DraftComment]) async throws {
        var payload: [String: Any] = [
            "commit_id": commitID,
            "event": verdict.rawValue,
        ]
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { payload["body"] = trimmed }
        payload["comments"] = comments.map { draft -> [String: Any] in
            var entry: [String: Any] = [
                "path": draft.path,
                "line": draft.line,
                "side": "RIGHT",
                "body": draft.body,
            ]
            // GitHub rejects start_line when it equals line, so a single-line
            // note must be sent without one.
            if let start = draft.startLine, start < draft.line {
                entry["start_line"] = start
                entry["start_side"] = "RIGHT"
            }
            return entry
        }
        let json = try JSONSerialization.data(withJSONObject: payload)
        // Piped in rather than passed as -f pairs: a note is free-form
        // markdown and the nested comments array has no -f spelling.
        let r = try await runner.run("gh", arguments: [
            "api", "-X", "POST", "repos/{owner}/{repo}/pulls/\(number)/reviews",
            "--input", "-",
        ], currentDirectory: repoDir, stdin: json)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
    }

    public func replyToComment(repoDir: URL, number: Int, commentID: Int,
                               body: String) async throws -> ReviewComment? {
        let r = try await runner.run("gh", arguments: [
            "api", "-X", "POST",
            "repos/{owner}/{repo}/pulls/\(number)/comments/\(commentID)/replies",
            "-f", "body=\(body)",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        return try? JSONDecoder().decode(RawComment.self, from: Data(r.stdout.utf8)).comment
    }

    /// The signed-in login, so the UI can tell which comments are the user's
    /// own and therefore editable.
    public func currentUser(repoDir: URL) async throws -> String {
        let r = try await runner.run("gh", arguments: ["api", "user", "--jq", ".login"],
                                     currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public func updateComment(repoDir: URL, commentID: Int,
                              body: String) async throws -> ReviewComment? {
        let r = try await runner.run("gh", arguments: [
            "api", "-X", "PATCH",
            "repos/{owner}/{repo}/pulls/comments/\(commentID)",
            "-f", "body=\(body)",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        return try? JSONDecoder().decode(RawComment.self, from: Data(r.stdout.utf8)).comment
    }

    public func deleteComment(repoDir: URL, commentID: Int) async throws {
        let r = try await runner.run("gh", arguments: [
            "api", "-X", "DELETE", "repos/{owner}/{repo}/pulls/comments/\(commentID)",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
    }

    /// Starts a new review thread on a line, or on a range when `startLine`
    /// is given.
    ///
    /// `commitID` must be the PR head the lines were read from; GitHub
    /// rejects a comment anchored to a commit the line numbers do not match.
    @discardableResult
    public func createComment(repoDir: URL, number: Int, commitID: String,
                              path: String, line: Int, startLine: Int?,
                              side: String = "RIGHT", body: String) async throws -> ReviewComment? {
        var args = [
            "api", "-X", "POST",
            "repos/{owner}/{repo}/pulls/\(number)/comments",
            "-f", "body=\(body)",
            "-f", "commit_id=\(commitID)",
            "-f", "path=\(path)",
            "-F", "line=\(line)",
            "-f", "side=\(side)",
        ]
        // GitHub rejects start_line when it equals line, so a single-line
        // selection must be sent as a plain line comment.
        if let startLine, startLine < line {
            args += ["-F", "start_line=\(startLine)", "-f", "start_side=\(side)"]
        }
        let r = try await runner.run("gh", arguments: args, currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        return try? JSONDecoder().decode(RawComment.self, from: Data(r.stdout.utf8)).comment
    }

    public func resolveThread(repoDir: URL, threadID: String) async throws {
        let mutation = "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}"
        let r = try await runner.run("gh", arguments: [
            "api", "graphql", "-f", "query=\(mutation)", "-f", "id=\(threadID)",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
    }

    /// Everyone who has contributed to the repository, most active first.
    ///
    /// The author filter cannot be built from the PRs currently on screen: on
    /// a repository with two hundred engineers the page you are looking at
    /// holds a handful of them, and the person you want is usually not one.
    /// GitHub returns this sorted by commit count, which is the order a
    /// picker wants anyway. Capped rather than paginated to exhaustion — past
    /// a few hundred the list is a search box, not a list.
    public func fetchContributors(repoDir: URL, limit: Int = 500) async throws -> [String] {
        let r = try await runner.run("gh", arguments: [
            "api", "repos/{owner}/{repo}/contributors?per_page=100",
            "--paginate", "--jq", ".[].login",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        var seen = Set<String>()
        var logins: [String] = []
        for line in r.stdout.split(separator: "\n") {
            let login = line.trimmingCharacters(in: .whitespaces)
            guard !login.isEmpty, seen.insert(login).inserted else { continue }
            logins.append(login)
            if logins.count >= limit { break }
        }
        return logins
    }

    /// The git remote that points at the repository `gh` is talking to.
    ///
    /// In a fork checkout these are different repositories: `gh` resolves the
    /// upstream it was configured with, while `origin` is the fork. Fetching
    /// `pull/N/head` from the wrong one fails with "couldn't find remote ref",
    /// which silently cost the full-context diff, the head SHA, and with it
    /// the ability to comment. Falls back to "origin" when nothing matches.
    public func remoteName(repoDir: URL, nameWithOwner: String) async -> String {
        guard let r = try? await runner.run("git", arguments: ["remote", "-v"],
                                            currentDirectory: repoDir),
              r.exitCode == 0 else { return "origin" }
        return GitRemotes.matching(nameWithOwner: nameWithOwner, in: r.stdout) ?? "origin"
    }

    public func checkAvailability() async -> (ghInstalled: Bool, ghAuthed: Bool) {
        guard let which = try? await runner.run("which", arguments: ["gh"], currentDirectory: nil), which.exitCode == 0 else {
            return (false, false)
        }
        let auth = try? await runner.run("gh", arguments: ["auth", "status"], currentDirectory: nil)
        return (true, (auth?.exitCode ?? 1) == 0)
    }
}
