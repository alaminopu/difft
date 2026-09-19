import SwiftUI
import DifftServices
import DifftUI

/// The side panel: what is left to deal with, and a place to ask about it.
struct RightPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var pendingAsk: (text: String, chip: String)?
    @Binding var tab: Int

    private var selection: Binding<PanelTab> {
        Binding(get: { PanelTab(rawValue: tab) ?? .queue }, set: { tab = $0.rawValue })
    }

    var body: some View {
        let controller = model.agent
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Text(selection.wrappedValue == .queue ? "Review queue" : "Ask Claude")
                    .font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
                Spacer(minLength: 0)
                SegmentedControl(selection: selection,
                                 options: [(.queue, "Queue"), (.ask, "Ask")])
            }
            .padding(.horizontal, Spacing.lg)
            .frame(height: Chrome.paneHeader)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }

            if let session = model.session {
                switch selection.wrappedValue {
                case .queue: QueueTab(session: session)
                case .ask: ChatTab(session: session, controller: controller, pendingAsk: $pendingAsk)
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: pendingAsk?.chip) { if pendingAsk != nil { tab = PanelTab.ask.rawValue } }
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
            LazyVStack(alignment: .leading, spacing: Spacing.md) {
                if session.data.chat.isEmpty {
                    Text("Ask about this pull request, or select lines in the diff and "
                         + "choose Ask Claude. It reads the code in the PR\u{2019}s worktree and "
                         + "cannot change it.")
                        .font(Typography.control).foregroundStyle(Palette.textTertiary)
                        .lineSpacing(Typography.bodyLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(session.data.chat.enumerated()), id: \.offset) { _, msg in
                    let mine = msg.role == "user"
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if let chip = msg.contextChip { ContextChip(text: chip) }
                        MarkdownBodyView(text: msg.text)
                            .padding(.horizontal, mine ? Spacing.md : 0)
                            .padding(.vertical, mine ? Spacing.sm : 0)
                            .background(mine ? Palette.activeChip : .clear,
                                        in: RoundedRectangle(cornerRadius: Radius.lg))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        Button("Copy") { AppModel.copy(msg.text) }
                    }
                }
                // Only for runs that end up in this transcript. Reviewing and
                // Explaining answer into their own panes, and their narration
                // showing here read as the explanation being posted to chat.
                if case .running = session.agentState,
                   ChatTab.streamsHere(controller.lastRunLabel),
                   !controller.streamingText.isEmpty {
                    Text(controller.streamingText)
                        .font(Typography.body).foregroundStyle(Palette.textSecondary)
                        .lineSpacing(Typography.bodyLineSpacing)
                }
            }
            .padding(Spacing.lg)
        }
        AgentRunBar(session: session)
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let chip = pendingAsk?.chip {
                HStack(spacing: Spacing.xs) {
                    ContextChip(text: chip)
                    Button { pendingAsk = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.textTertiary)
                    .accessibilityLabel("Remove the selection")
                }
            }
            HStack(spacing: Spacing.sm) {
                TextField("Ask about this PR\u{2026}", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .lineLimit(1...5)
                    .onSubmit { submit() }
                Button { submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(width: 22, height: 22)
                        .background(Palette.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(question.isEmpty || !session.agentState.canStart)
                .opacity(question.isEmpty || !session.agentState.canStart ? 0.35 : 1)
                .accessibilityLabel("Ask")
            }
            .padding(.leading, Spacing.md).padding(.trailing, Spacing.xs + 1)
            .padding(.vertical, Spacing.xs + 1)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: Radius.lg))
            .overlay { RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Palette.cardBorder) }
        }
        .padding(Spacing.md)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
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

/// The lines a question is about: "form/main.py:105-106".
struct ContextChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.identifier)
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Compact run indicator shared by all panel tabs: indeterminate progress
/// bar, run label, and an X to cancel. Shown only while an agent runs.
struct AgentRunBar: View {
    @ObservedObject var session: ReviewSession

    var body: some View {
        if case .running(let label) = session.agentState {
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("\(label)\u{2026}").font(Typography.control)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 0)
                Button("Stop") {
                    NotificationCenter.default.post(name: .difftCancelAgent, object: nil)
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Cancel agent run")
            }
            .padding(.horizontal, Spacing.lg)
            .frame(height: 34)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }
}

struct AgentStatusView: View {
    @ObservedObject var session: ReviewSession
    // Lives in the always-mounted status bar, so it is the reliable place to
    // pop the (default-hidden) assistant panel open when results land.
    @AppStorage(ShellPref.showPanel) private var showRightPanel = true
    @AppStorage(ShellPref.panelTab) private var panelTab = PanelTab.queue.rawValue
    /// The PR whose findings this view is tracking, so a count that changed
    /// because the session changed is not read as a run finishing.
    @State private var openFor: Int?

    var body: some View {
        Group {
            switch session.agentState {
            case .running:
                // Running state renders in the assistant panel's AgentRunBar;
                // duplicating it here read as two competing indicators.
                EmptyView()
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.removedText).lineLimit(1).help(msg)
            default: EmptyView()
            }
        }
        // Only when a run just produced them. This view sits in the
        // always-mounted status bar, so switching PRs compares the outgoing
        // session's count with the incoming one's — opening a PR that already
        // had findings saved forced the panel open as if a review had landed.
        .onChange(of: session.data.findings.count) { old, new in
            guard new > old, session.data.pr.number == openFor else { return }
            // New findings are new queue items, so that is the face to show.
            panelTab = PanelTab.queue.rawValue
            showRightPanel = true
        }
        .onAppear { openFor = session.data.pr.number }
        .onChange(of: session.data.pr.number) { _, number in openFor = number }
    }
}

extension Notification.Name { static let difftCancelAgent = Notification.Name("difftCancelAgent") }
