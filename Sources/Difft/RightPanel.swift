import SwiftUI
import DifftServices
import DifftUI

struct RightPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var pendingAsk: (text: String, chip: String)?
    @Binding var tab: Int

    var body: some View {
        let controller = model.agent
        VStack(spacing: 0) {
            Text(["Claude", "Findings"][min(max(tab, 0), 1)])
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            if let session = model.session {
                switch tab {
                case 0: ChatTab(session: session, controller: controller, pendingAsk: $pendingAsk)
                default: FindingsTab(session: session, controller: controller)
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: pendingAsk?.chip) { if pendingAsk != nil { tab = 0 } }
        .onAppear {
            // The tab index is persisted, and there used to be a third tab.
            // A session restored onto the removed index would show Findings
            // while no tool-strip icon looked selected.
            if tab > 1 { tab = 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .difftCancelAgent)) { _ in model.agent.cancel() }
    }
}

// `ReviewSession` and `AgentController` are both nested ObservableObjects
// reached through @EnvironmentObject AppModel; per project ruling #2 (see
// FileDiffContainer in CenterView.swift) any view that reads their published
// state for rendering must hold them as @ObservedObject directly — a plain
// `let`/computed reference (or reading through `model.session?...`) doesn't
// subscribe to their `objectWillChange`, so streaming text, new chat
// messages, findings, and agentState updates would never trigger a re-render.
struct ChatTab: View {
    @ObservedObject var session: ReviewSession
    @ObservedObject var controller: AgentController
    @Binding var pendingAsk: (text: String, chip: String)?
    @State private var question = ""

    /// Runs whose result is appended to `session.data.chat`, and so whose
    /// progress belongs in this transcript.
    static func streamsHere(_ label: String?) -> Bool {
        label == "Clarifying" || label == "Fixing"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.data.chat.enumerated()), id: \.offset) { _, msg in
                    VStack(alignment: .leading, spacing: 2) {
                        if let chip = msg.contextChip {
                            Text(chip).font(.caption.monospaced())
                                .padding(3).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                        MarkdownBodyView(text: msg.text)
                            .padding(8)
                            .background(msg.role == "user" ? Palette.activeChip : Palette.surface,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(maxWidth: .infinity, alignment: msg.role == "user" ? .trailing : .leading)
                }
                // Only for runs that end up in this transcript. Reviewing and
                // Explaining answer into their own panes, and their narration
                // showing here read as the explanation being posted to chat.
                if case .running = session.agentState,
                   ChatTab.streamsHere(controller.lastRunLabel),
                   !controller.streamingText.isEmpty {
                    Text(controller.streamingText).padding(8).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
        AgentRunBar(session: session)
        if let chip = pendingAsk?.chip {
            HStack {
                Text(chip).font(.caption.monospaced())
                Button("✕") { pendingAsk = nil }.buttonStyle(.plain)
            }.padding(.horizontal, 8)
        }
        HStack {
            TextField("Ask about this PR…", text: $question).onSubmit { submit() }
            Button("Ask") { submit() }
                .disabled(question.isEmpty || !session.agentState.canStart)
        }.padding(8)
    }

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // onSubmit (Return) has no disabled state like the Ask button —
        // guard here or an empty question goes to the agent.
        guard !q.isEmpty, session.agentState.canStart else { return }
        let sel = pendingAsk
        question = ""; pendingAsk = nil
        Task { await controller.ask(question: q, selection: sel) }
    }
}

/// Compact companion to the Review pane, not a second copy of it.
///
/// The findings list moved to its own centre pane — it needs width to group by
/// file, filter by severity and show each finding's failure scenario. What is
/// useful in a 300pt column is the score and a way through to the pane.
struct FindingsTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    @ObservedObject var controller: AgentController

    private var findings: [Finding] { session.data.findings.filter { !$0.dismissed } }
    private var isRunning: Bool {
        if case .running(let label) = session.agentState {
            return label == "Reviewing" || label == "Verifying"
        }
        return false
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            if isRunning {
                // Said "No review yet" all the way through a run, which read
                // as the click having done nothing.
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(controller.lastRunLabel == "Verifying" ? "Verifying…" : "Reviewing…")
                        .font(Typography.meta).foregroundStyle(.secondary)
                }
            } else if session.data.reviewStamp == nil {
                Text("No review yet.")
                    .font(Typography.meta).foregroundStyle(.secondary)
            } else if findings.isEmpty {
                Label("No defects found", systemImage: "checkmark.seal")
                    .font(Typography.body).foregroundStyle(Palette.added)
            } else {
                VStack(spacing: Spacing.xs) {
                    ForEach(["high", "medium", "low"], id: \.self) { severity in
                        let n = findings.count { $0.severity.lowercased() == severity }
                        if n > 0 {
                            HStack(spacing: Spacing.xs) {
                                SeverityChip(severity: severity)
                                Text("\(n)").font(Typography.metaDigits)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxWidth: 160)
            }
            Button {
                Task { await model.review() }
            } label: {
                Label(session.data.reviewStamp == nil ? "Run Claude review" : "Open review",
                      systemImage: "checklist")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning || (!session.agentState.canStart && session.data.reviewStamp == nil))
            .help("Findings open in their own pane (\u{21E7}\u{2318}F)")
            Spacer()
            AgentRunBar(session: session)
        }
        .padding(.top, Spacing.md)
        .frame(maxWidth: .infinity)
    }
}

/// Compact run indicator shared by all panel tabs: indeterminate progress
/// bar, run label, and an X to cancel. Shown only while an agent runs.
struct AgentRunBar: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        if case .running(let label) = session.agentState {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Button {
                    NotificationCenter.default.post(name: .difftCancelAgent, object: nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .accessibilityLabel("Cancel agent run")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct AgentStatusView: View {
    @ObservedObject var session: ReviewSession
    // Lives in the always-mounted status bar, so it is the reliable place to
    // pop the (default-hidden) assistant panel open when results land.
    @AppStorage("showRightPanel") private var showRightPanel = false

    var body: some View {
        Group {
            switch session.agentState {
            case .running:
                // Running state renders in the assistant panel's AgentRunBar;
                // duplicating it here read as two competing indicators.
                EmptyView()
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).lineLimit(1).help(msg)
            default: EmptyView()
            }
        }
        .onChange(of: session.data.findings.count) { _, n in
            if n > 0 { showRightPanel = true }
        }
    }
}

extension Notification.Name { static let difftCancelAgent = Notification.Name("difftCancelAgent") }
