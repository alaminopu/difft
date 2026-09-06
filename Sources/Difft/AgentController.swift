import SwiftUI
import DifftCore
import DifftServices

@MainActor
final class AgentController: ObservableObject {
    @Published var streamingText = ""
    struct ToolCall: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let detail: String?
    }
    @Published var toolActivity: [ToolCall] = []
    /// Label of the current/most recent run ("Clarifying"/"Reviewing") so
    /// tabs can show only the activity that belongs to them instead of
    /// another run's stale log.
    @Published var lastRunLabel: String?
    /// When the current run started. A thorough review is minutes long, and a
    /// spinner with no clock on it is indistinguishable from a hang.
    @Published var runStartedAt: Date?

    private let model: AppModel
    private let agent = AgentService()
    /// Set by `cancel()`; consulted when a run's body throws (or reports an
    /// error result) so a user-requested cancel lands back on `.idle`
    /// instead of `.failed`. Reset at the start of every run.
    private var userCancelled = false
    private lazy var worktrees = WorktreeManager(
        runner: model.processRunner,
        baseDir: AppModel.appSupportDir.appendingPathComponent("worktrees"))

    init(model: AppModel) { self.model = model }

    private func withWorktree(_ label: String, _ body: (URL) async throws -> Void) async {
        guard let session = model.session, session.agentState.canStart, let repoDir = model.repoDir else { return }
        userCancelled = false
        session.agentState = .running(label)
        streamingText = ""; toolActivity = []
        lastRunLabel = label
        runStartedAt = Date()
        do {
            let wt = try await worktrees.ensureWorktree(
                cloneDir: repoDir, repoName: model.repoName, prNumber: session.data.pr.number)
            try await body(wt)
            // Only clobber to `.idle` if nothing else already moved state on
            // — `consume()` may have set `.failed` from a result(is_error:
            // true) event while the underlying process still exits 0, and
            // that failure must not be silently overwritten here.
            if case .running = session.agentState { session.agentState = .idle }
        } catch {
            session.agentState = .afterFailure(userCancelled: userCancelled, message: "\(label): \(error.localizedDescription)")
        }
        runStartedAt = nil
        do {
            try model.sessionStore.save(session.data)
        } catch {
            model.errorBanner = "Failed to save session: \(error.localizedDescription)"
        }
    }

    func ask(question: String, selection: (text: String, chip: String)?) async {
        guard let session = model.session else { return }
        session.data.chat.append(ChatMessage(role: "user", text: question, contextChip: selection?.chip))
        let task = AgentTask.clarify(
            pr: session.data.pr,
            selection: selection.map { "\($0.chip)\n\($0.text)" },
            question: question,
            history: session.data.chat.dropLast().suffix(10).map { $0 })
        await withWorktree("Clarifying") { wt in
            var final = ""
            for try await event in agent.run(task, in: wt) {
                self.consume(event, accumulatingResult: &final)
            }
            session.data.chat.append(ChatMessage(role: "assistant",
                text: final.isEmpty ? self.streamingText : final, contextChip: nil))
        }
    }

    /// Two passes: find, then try to disprove. The verifier runs without the
    /// finder's reasoning in front of it, because a pass that can see why a
    /// finding was raised tends to agree with it. Anything it does not return
    /// is discarded — that filter is the whole point.
    func runReview() async {
        guard let session = model.session else { return }
        let summary = model.files.map { "\($0.path) (+\($0.additions)/−\($0.deletions))" }.joined(separator: "\n")
        await withWorktree("Reviewing") { wt in
            var found = ""
            for try await event in agent.run(
                    AgentTask.review(pr: session.data.pr, diffSummary: summary,
                                     fileCount: self.model.files.count), in: wt) {
                self.consume(event, accumulatingResult: &found)
            }
            let candidates = FindingsParser.parse(found.isEmpty ? self.streamingText : found)
            let head = try? await self.model.processRunner.run(
                "git", arguments: ["rev-parse", "HEAD"], currentDirectory: wt)
            let sha = head?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let stampSHA = (sha?.isEmpty ?? true) ? nil : sha

            guard !candidates.isEmpty else {
                session.data.findings = []
                session.data.reviewStamp = ReviewStamp(headSHA: stampSHA)
                return
            }

            session.agentState = .running("Verifying")
            self.lastRunLabel = "Verifying"
            self.streamingText = ""; self.toolActivity = []
            var checked = ""
            for try await event in agent.run(
                    AgentTask.verifyFindings(pr: session.data.pr, candidates: candidates), in: wt) {
                self.consume(event, accumulatingResult: &checked)
            }
            let survivors = FindingsParser.parseVerified(checked.isEmpty ? self.streamingText : checked)
            session.data.findings = survivors.sorted {
                $0.severityRank == $1.severityRank ? $0.file < $1.file : $0.severityRank < $1.severityRank
            }
            session.data.reviewStamp = ReviewStamp(
                headSHA: stampSHA,
                discarded: max(0, candidates.count - survivors.count))
        }
    }

    /// Walks the reviewer through the PR. Answers into `session.data
    /// .explanation` for the Explain pane to render — deliberately not into
    /// chat, where a structured walkthrough became an unscannable wall of
    /// text that scrolled away behind the next question.
    func runExplain() async {
        guard let session = model.session else { return }
        let summary = model.files.map { "\($0.path) (+\($0.additions)/−\($0.deletions))" }
            .joined(separator: "\n")
        let task = AgentTask.explain(pr: session.data.pr, diffSummary: summary)
        await withWorktree("Explaining") { wt in
            var final = ""
            for try await event in agent.run(task, in: wt) {
                self.consume(event, accumulatingResult: &final)
            }
            guard let parsed = ExplanationParser.parse(final.isEmpty ? self.streamingText : final) else {
                // A run that produced nothing decodable must not blank out a
                // good explanation from a previous run.
                session.agentState = .failed("Explaining: no walkthrough came back")
                return
            }
            let head = try? await self.model.processRunner.run(
                "git", arguments: ["rev-parse", "HEAD"], currentDirectory: wt)
            let sha = head?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            session.data.explanation = parsed.stamped(headSHA: (sha?.isEmpty ?? true) ? nil : sha)
        }
    }

    /// Asks Claude to fix one finding in the PR worktree, then reports the
    /// resulting patch in chat. Edits stay in the worktree — never the user's
    /// clone — and nothing is committed.
    func runFix(_ finding: Finding) async {
        guard let session = model.session else { return }
        let task = AgentTask.fix(pr: session.data.pr, finding: finding)
        session.data.chat.append(ChatMessage(
            role: "user",
            text: "Fix this finding: \(finding.explanation)",
            contextChip: "\(finding.file):\(finding.line)"))
        await withWorktree("Fixing") { wt in
            var final = ""
            for try await event in agent.run(task, in: wt) {
                self.consume(event, accumulatingResult: &final)
            }
            let summary = final.isEmpty ? self.streamingText : final
            let patch = try? await self.model.processRunner.run(
                "git", arguments: ["diff", "--stat"], currentDirectory: wt)
            let changed = (patch?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = changed.isEmpty
                ? summary + "\n\n_No files changed in the worktree._"
                : summary + "\n\nChanges in the PR worktree:\n```\n\(changed)\n```"
            session.data.chat.append(ChatMessage(role: "assistant", text: text, contextChip: nil))
        }
    }


    func cancel() {
        userCancelled = true
        agent.cancel()
        model.session?.agentState = .idle
    }

    private func consume(_ event: AgentEvent, accumulatingResult final: inout String) {
        switch event {
        case .textDelta(let t): streamingText += t
        case .toolUse(let name, let detail):
            toolActivity.append(ToolCall(name: name, detail: detail))
        case .result(let isError, let text):
            final = text
            if isError { model.session?.agentState = .afterFailure(userCancelled: userCancelled, message: text) }
        case .unknown: break
        }
    }
}
