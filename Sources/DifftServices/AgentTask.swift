import Foundation

public enum AgentTask: Sendable {
    case clarify(pr: PullRequest, selection: String?, question: String, history: [ChatMessage])
    case review(pr: PullRequest, diffSummary: String)
    /// Write a minimal fix for one review finding. Gets file-edit tools but
    /// no shell — it changes files in the PR's disposable worktree and runs
    /// nothing, so it never needs `--dangerously-skip-permissions`.
    case fix(pr: PullRequest, finding: Finding)

    public var prompt: String {
        switch self {
        case let .clarify(pr, selection, question, history):
            var p = """
            You are helping review GitHub PR #\(pr.number): \(pr.title)

            PR description:
            \(pr.body)

            You are inside a checkout of the PR branch. You may Read/Grep/Glob to build context.
            """
            if !history.isEmpty {
                p += "\n\nConversation so far:\n"
                for m in history { p += "\(m.role): \(m.text)\n" }
            }
            if let sel = selection {
                p += "\n\nThe reviewer selected these diff lines:\n\(sel)\n"
            }
            p += "\nReviewer question: \(question)\nAnswer concisely and concretely."
            return p

        case let .review(pr, diffSummary):
            return """
            Review GitHub PR #\(pr.number): \(pr.title)

            PR description:
            \(pr.body)

            Changed files summary:
            \(diffSummary)

            You are inside a checkout of the PR branch. Read the changed files and review for bugs, \
            security issues, and regressions. Then output your findings as a fenced json block: \
            a JSON array of objects with keys "severity" (high|medium|low), "file", "line" (integer), \
            "explanation". Output the json block even if empty.
            """

        case let .fix(pr, finding):
            return """
            You are fixing one review finding in GitHub PR #\(pr.number): \(pr.title)

            Finding (\(finding.severity)) at \(finding.file):\(finding.line)
            \(finding.explanation)

            You are inside a checkout of the PR branch. Make the smallest change
            that addresses the finding:
            - Edit only what the finding requires; do not refactor around it.
            - Match the surrounding code's style and conventions.
            - If the finding is wrong or the fix needs a decision only the author
              can make, change nothing and say so.
            - Do not commit, stage, or push anything.

            Finish with a short summary: what you changed and why, or why you
            changed nothing.
            """
        }
    }

    public var cliArguments: [String] {
        let base = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        switch self {
        case .clarify, .review:
            return base + ["--allowedTools", "Read,Grep,Glob"]
        case .fix:
            // Edit/Write but deliberately no Bash: the agent changes files in
            // the worktree, it does not run anything.
            return base + ["--allowedTools", "Read,Grep,Glob,Edit,Write"]
        }
    }
}
