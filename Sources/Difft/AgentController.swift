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

    func runReview() async {
        guard let session = model.session else { return }
        let summary = model.files.map { "\($0.path) (+\($0.additions)/−\($0.deletions))" }.joined(separator: "\n")
        let task = AgentTask.review(pr: session.data.pr, diffSummary: summary)
        await withWorktree("Reviewing") { wt in
            var final = ""
            for try await event in agent.run(task, in: wt) {
                self.consume(event, accumulatingResult: &final)
            }
            session.data.findings = FindingsParser.parse(final)
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
