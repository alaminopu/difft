import Foundation

public struct Finding: Codable, Equatable, Sendable, Identifiable {
    public let severity: String
    public let file: String
    public let line: Int
    public let explanation: String
    /// Concrete inputs or state that produce the wrong result. Required of the
    /// agent, because a finding that cannot describe its own failure is
    /// usually speculation — writing the failure is what forces that out.
    public let failureScenario: String
    /// "correctness", "security", "convention", … Free-form: the taxonomy is
    /// the agent's, and the view only groups by it.
    public let category: String
    /// Survived the verification pass with proof, versus survived but could
    /// not be proven from the diff alone.
    public let confidence: Confidence
    /// Triaged away by the reader. Kept rather than deleted so the count can
    /// still say what was dismissed.
    public var dismissed: Bool

    public enum Confidence: String, Codable, Sendable {
        case confirmed, plausible
    }

    /// Stable across re-renders without being stored: findings arrive as a
    /// list and are never edited except to dismiss.
    public var id: String { "\(file):\(line):\(explanation.prefix(64))" }

    public init(severity: String, file: String, line: Int, explanation: String,
                failureScenario: String = "", category: String = "",
                confidence: Confidence = .plausible, dismissed: Bool = false) {
        self.severity = severity; self.file = file; self.line = line
        self.explanation = explanation; self.failureScenario = failureScenario
        self.category = category; self.confidence = confidence; self.dismissed = dismissed
    }

    enum CodingKeys: String, CodingKey {
        case severity, file, line, explanation, failureScenario, category, confidence, dismissed
    }

    /// Tolerant like the explanation decoder: the agent writes this shape, and
    /// one odd field must not cost the whole finding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        severity = ((try? c.decodeIfPresent(String.self, forKey: .severity)) ?? nil) ?? "low"
        file = ((try? c.decodeIfPresent(String.self, forKey: .file)) ?? nil) ?? ""
        if let n = (try? c.decodeIfPresent(Int.self, forKey: .line)) ?? nil {
            line = n
        } else if let s = (try? c.decodeIfPresent(String.self, forKey: .line)) ?? nil {
            line = Int(s) ?? 0
        } else {
            line = 0
        }
        explanation = ((try? c.decodeIfPresent(String.self, forKey: .explanation)) ?? nil) ?? ""
        failureScenario = ((try? c.decodeIfPresent(String.self, forKey: .failureScenario)) ?? nil) ?? ""
        category = ((try? c.decodeIfPresent(String.self, forKey: .category)) ?? nil) ?? ""
        let raw = ((try? c.decodeIfPresent(String.self, forKey: .confidence)) ?? nil) ?? ""
        confidence = Confidence(rawValue: raw) ?? .plausible
        dismissed = ((try? c.decodeIfPresent(Bool.self, forKey: .dismissed)) ?? nil) ?? false
    }

    public var severityRank: Int {
        switch severity.lowercased() {
        case "high": return 0
        case "medium": return 1
        default: return 2
        }
    }
}

/// When a review ran and against what, so stale findings can say so — the
/// same provenance the walkthrough carries.
public struct ReviewStamp: Codable, Equatable, Sendable {
    public var headSHA: String?
    public var generatedAt: Date
    /// Candidates the verification pass threw out. Worth showing: it is the
    /// evidence that the filter did something.
    public var discarded: Int
    public init(headSHA: String?, generatedAt: Date = Date(), discarded: Int = 0) {
        self.headSHA = headSHA; self.generatedAt = generatedAt; self.discarded = discarded
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
    /// Provenance of the last review run. Absent means no review has run.
    public var reviewStamp: ReviewStamp?
    /// The PR walkthrough, kept so reopening a PR does not re-run the agent.
    public var explanation: DiffExplanation?
    public init(pr: PullRequest, repoDir: String, viewedFiles: Set<String>,
                chat: [ChatMessage], findings: [Finding],
                reviewStamp: ReviewStamp? = nil,
                explanation: DiffExplanation? = nil) {
        self.pr = pr; self.repoDir = repoDir; self.viewedFiles = viewedFiles
        self.chat = chat; self.findings = findings
        self.reviewStamp = reviewStamp; self.explanation = explanation
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

/// The centre pane's mode. `.diff` covers both the PR overview and an open
/// file — which of those shows is decided by `selectedFile`.
public enum CenterPane: String, Codable, Sendable {
    case diff, comments, commits, explain, review
}

@MainActor
public final class ReviewSession: ObservableObject {
    @Published public var data: SessionData
    @Published public var selectedFile: String?
    @Published public var selectedLines: ClosedRange<Int>?
    /// What the centre pane is showing. One value rather than a flag per
    /// pane: as separate booleans every new pane had to remember to clear
    /// every other one at eleven call sites, and a miss showed two panes'
    /// state at once.
    @Published public var pane: CenterPane = .diff
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
