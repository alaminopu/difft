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
    public let authorLogin: String
    public init(number: Int, title: String, body: String, headRefName: String,
                baseRefName: String? = nil, authorLogin: String) {
        self.number = number; self.title = title; self.body = body
        self.headRefName = headRefName; self.baseRefName = baseRefName
        self.authorLogin = authorLogin
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

public enum GitHubServiceError: Error, Equatable {
    case commandFailed(String)
}

public final class GitHubService: Sendable {
    private let runner: ProcessRunning
    public init(runner: ProcessRunning = DefaultProcessRunner()) { self.runner = runner }

    public func listPRs(repoDir: URL) async throws -> [PullRequest] {
        let r = try await runner.run("gh", arguments: ["pr", "list", "--json", "number,title,body,headRefName,baseRefName,author", "--limit", "50"], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
        struct Raw: Codable { struct Author: Codable { let login: String }
            let number: Int; let title: String; let body: String; let headRefName: String
            let baseRefName: String?; let author: Author }
        let raws = try JSONDecoder().decode([Raw].self, from: Data(r.stdout.utf8))
        return raws.map { PullRequest(number: $0.number, title: $0.title, body: $0.body, headRefName: $0.headRefName,
                                      baseRefName: $0.baseRefName, authorLogin: $0.author.login) }
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

    public func replyToComment(repoDir: URL, number: Int, commentID: Int, body: String) async throws {
        let r = try await runner.run("gh", arguments: [
            "api", "-X", "POST",
            "repos/{owner}/{repo}/pulls/\(number)/comments/\(commentID)/replies",
            "-f", "body=\(body)",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
    }

    public func resolveThread(repoDir: URL, threadID: String) async throws {
        let mutation = "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}"
        let r = try await runner.run("gh", arguments: [
            "api", "graphql", "-f", "query=\(mutation)", "-f", "id=\(threadID)",
        ], currentDirectory: repoDir)
        guard r.exitCode == 0 else { throw GitHubServiceError.commandFailed(r.stderr) }
    }

    public func checkAvailability() async -> (ghInstalled: Bool, ghAuthed: Bool) {
        guard let which = try? await runner.run("which", arguments: ["gh"], currentDirectory: nil), which.exitCode == 0 else {
            return (false, false)
        }
        let auth = try? await runner.run("gh", arguments: ["auth", "status"], currentDirectory: nil)
        return (true, (auth?.exitCode ?? 1) == 0)
    }
}
