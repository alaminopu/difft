import SwiftUI
import DifftCore
import DifftServices

/// The text a run is streaming, in an object of its own.
///
/// As a published property of the controller, every token re-rendered every
/// view observing the controller — the Walkthrough and Findings panes too,
/// which never read it, and a long walkthrough redrawn dozens of times a
/// second while being regenerated. Only the chat's live bubble watches this.
@MainActor
final class StreamBuffer: ObservableObject {
    @Published var text = ""
}

@MainActor
final class AgentController: ObservableObject {
    let stream = StreamBuffer()
    var streamingText: String {
        get { stream.text }
        set { stream.text = newValue }
    }
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

    /// One run at a time across sessions. Run state lives on the session, so
    /// closing a PR mid-run and reopening it gave a fresh, idle session that
    /// would start a second run beside the first — sharing this controller's
    /// stream text, with Stop reaching only one of them.
    private var isRunning = false

    private func withWorktree(_ label: String, _ body: (URL) async throws -> Void) async {
        guard !isRunning, let session = model.session, session.agentState.canStart,
              let repoDir = model.repoDir else { return }
        isRunning = true
        defer { isRunning = false }
        userCancelled = false
        session.agentState = .running(label)
        streamingText = ""; toolActivity = []
        lastRunLabel = label
        runStartedAt = Date()
        do {
            let wt = try await worktrees.ensureWorktree(
                cloneDir: repoDir, repoName: model.repoName, prNumber: session.data.pr.number,
                // In a fork checkout `origin` is the fork and the PR ref lives
                // on the upstream `gh` resolves; fetching from the wrong one
                // fails outright.
                remote: await model.remoteName(repoDir: repoDir))
            try await body(wt)
            // Only clobber to `.idle` if nothing else already moved state on
            // — `consume()` may have set `.failed` from a result(is_error:
            // true) event while the underlying process still exits 0, and
            // that failure must not be silently overwritten here.
            if case .running = session.agentState { session.agentState = .idle }
        } catch {
            session.agentState = .afterFailure(userCancelled: userCancelled, message: "\(label): \(error.localizedDescription)")
        }
        // A run takes minutes; finishing used to be silent, so you either
        // watched a spinner or came back later and guessed.
        if !userCancelled {
            RunNotifier.shared.runFinished(
                label: label, pr: session.data.pr.number, title: session.data.pr.title,
                outcome: Self.outcome(of: session.agentState, label: label))
        }
        runStartedAt = nil
        // A session closed mid-run has been read back from disk by now if the
        // PR was reopened, and edited there. Saving this orphaned copy would
        // put back the file as it was when the run began.
        guard model.session === session else { return }
        model.sessionStore.saveInBackground(session.data) { [weak model] error in
            model?.errorBanner = "Failed to save session: \(error.localizedDescription)"
        }
    }

    /// One line saying what the run produced, for the notification body.
    private static func outcome(of state: AgentState, label: String) -> String {
        if case .failed(let message) = state { return message }
        switch label {
        case "Reviewing", "Verifying": return "The review is ready."
        case "Fixing": return "The fix is written — review the patch."
        case "Explaining": return "The walkthrough is ready."
        case "Clarifying": return "Your question has an answer."
        default: return "Done."
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
            // Stop ends the process cleanly, so the loop above just finishes
            // and the partial narration parsed as "no findings" — which then
            // replaced the saved review, dismissals and all, and called the
            // PR clean. A cancelled or failed pass writes nothing.
            guard self.stillRunning(session) else { return }
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
            guard self.stillRunning(session) else { return }
            guard let survivors = FindingsParser.verifiedIfReadable(
                    checked.isEmpty ? self.streamingText : checked) else {
                // An answer that is not the expected JSON rejected nothing;
                // treating it as "all rejected" silently emptied the review.
                session.agentState = .failed(
                    "The verification pass returned an answer Difft could not read. "
                    + "The previous findings were kept.")
                return
            }
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
            // A new walkthrough asks new questions; keeping the old answers
            // would show them already answered.
            session.quizAnswers = [:]
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


    /// Whether the run is still one whose results should be kept: not
    /// cancelled, and not already failed by an error result.
    private func stillRunning(_ session: ReviewSession) -> Bool {
        guard !userCancelled else { return false }
        if case .running = session.agentState { return true }
        return false
    }

    /// Stops a run for good because its PR is going away, without touching
    /// whichever session is open next.
    func cancelForClose() {
        guard isRunning else { return }
        cancel()
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
