import Foundation

public struct Finding: Codable, Equatable, Sendable {
    public let severity: String
    public let file: String
    public let line: Int
    public let explanation: String
    public init(severity: String, file: String, line: Int, explanation: String) {
        self.severity = severity; self.file = file; self.line = line; self.explanation = explanation
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public let role: String
    public let text: String
    public let contextChip: String?
    public init(role: String, text: String, contextChip: String?) {
        self.role = role; self.text = text; self.contextChip = contextChip
    }
}

public struct SessionData: Codable, Equatable, Sendable {
    public var pr: PullRequest
    public var repoDir: String
    public var viewedFiles: Set<String>
    public var chat: [ChatMessage]
    public var findings: [Finding]
    public init(pr: PullRequest, repoDir: String, viewedFiles: Set<String>, chat: [ChatMessage], findings: [Finding]) {
        self.pr = pr; self.repoDir = repoDir; self.viewedFiles = viewedFiles
        self.chat = chat; self.findings = findings
    }
}

public enum AgentState: Equatable, Sendable {
    case idle
    case running(String)
    case failed(String)

    /// Resolves the terminal state after a run body throws or reports an
    /// error result. A user-initiated cancel should land back on `.idle`
    /// rather than being reported as a failure, even though the SIGTERM
    /// `cancel()` sends may still surface as a non-zero exit / thrown error
    /// (or an error result) from the in-flight run.
    public static func afterFailure(userCancelled: Bool, message: String) -> AgentState {
        userCancelled ? .idle : .failed(message)
    }

    /// Whether a new agent run is allowed to start from this state. A prior
    /// failure must not be a dead end — the spec requires retry-ability, so
    /// `.failed` is startable just like `.idle` (a new run resets state).
    /// Only `.running` blocks a new run.
    public var canStart: Bool {
        switch self {
        case .idle, .failed: return true
        case .running: return false
        }
    }
}

@MainActor
public final class ReviewSession: ObservableObject {
    @Published public var data: SessionData
    @Published public var selectedFile: String?
    @Published public var selectedLines: ClosedRange<Int>?
    /// Whether the centre pane shows every review comment instead of a diff.
    @Published public var showComments = false
    /// Whether the centre pane shows the PR's commits instead of a diff.
    @Published public var showCommits = false
    /// Commit whose own diff is open, drilled into from the commits list.
    @Published public var selectedCommit: Commit?
    /// File selected within that commit's diff.
    @Published public var selectedCommitFile: String?
    /// File whose section the comments list should scroll to when it opens,
    /// set when the list is entered from a particular file.
    @Published public var commentsScrollTarget: String?
    @Published public var agentState: AgentState = .idle
    public init(data: SessionData) { self.data = data }
    public func snapshot() -> SessionData { data }
    public func apply(_ newData: SessionData) { data = newData }
}
