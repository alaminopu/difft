import SwiftUI
import DifftServices
import DifftUI

struct RightPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var pendingAsk: (text: String, chip: String)?
    @Binding var tab: Int

    private func consumeExplain(_ controller: AgentController) {
        guard model.pendingExplainDiff else { return }
        model.pendingExplainDiff = false
        tab = 0
        Task {
            await controller.ask(
                question: "Explain this PR: summarize what it changes and why, then walk through the key changes file by file. Keep it concise.",
                selection: nil)
        }
    }

    var body: some View {
        let controller = model.agent
        VStack(spacing: 0) {
            Text(["Claude", "Findings", "Verify"][min(max(tab, 0), 2)])
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            if let session = model.session {
                switch tab {
                case 0: ChatTab(session: session, controller: controller, pendingAsk: $pendingAsk)
                case 1: FindingsTab(session: session, controller: controller,
                                    onAskFinding: { f in
                                        pendingAsk = (text: f.explanation, chip: "\(f.file):\(f.line)")
                                        tab = 0
                                    },
                                    onFixFinding: { f in
                                        tab = 0  // the fix streams into chat
                                        Task { await controller.runFix(f) }
                                    })
                default: VerifyTab(session: session, controller: controller)   // Task 15
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: pendingAsk?.chip) { if pendingAsk != nil { tab = 0 } }
        .onAppear { consumeExplain(controller) }
        .onChange(of: model.pendingExplainDiff) { consumeExplain(controller) }
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
                if case .running = session.agentState, !controller.streamingText.isEmpty {
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

struct FindingsTab: View {
    @ObservedObject var session: ReviewSession
    @ObservedObject var controller: AgentController
    var onAskFinding: (Finding) -> Void = { _ in }
    var onFixFinding: (Finding) -> Void = { _ in }
    @State private var fixTarget: Finding?

    var body: some View {
        VStack {
            Button("Run Claude review") { Task { await controller.runReview() } }
                .disabled(!session.agentState.canStart)
                .padding(.top, 8)
            List(Array(session.data.findings.enumerated()), id: \.offset) { _, f in
                VStack(alignment: .leading, spacing: 4) {
                    let sevColor: Color = f.severity == "high" ? Palette.removed
                        : f.severity == "medium" ? Palette.warning : Color.secondary
                    let fileName = String(f.file.split(separator: "/").last ?? "")
                    let dir = f.file.split(separator: "/").dropLast().joined(separator: "/")
                    HStack(spacing: 6) {
                        Text(f.severity.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(sevColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(sevColor.opacity(0.18), in: Capsule())
                        Text(verbatim: "\(fileName):\(f.line)")
                            .font(.callout.monospaced().bold())
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Fix it") { fixTarget = f }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(!session.agentState.canStart)
                            .help("Have Claude write a fix in the PR worktree")
                    }
                    if !dir.isEmpty {
                        Text(dir)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(f.file)
                    }
                    Text(f.explanation)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    session.selectedFile = f.file
                    // The diff view scrolls to and selects this line.
                    session.selectedLines = f.line...f.line
                }
                .contextMenu {
                    Button {
                        fixTarget = f
                    } label: {
                        Label("Fix this finding", systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(!session.agentState.canStart)
                    Button {
                        onAskFinding(f)
                    } label: {
                        Label("Ask Claude about this finding", systemImage: "sparkles")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "[\(f.severity)] \(f.file):\(f.line)\n\(f.explanation)", forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
            AgentRunBar(session: session)
        }
        .confirmationDialog("Let Claude edit files to fix this?",
                            isPresented: Binding(get: { fixTarget != nil },
                                                 set: { if !$0 { fixTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Write the fix") {
                if let f = fixTarget { onFixFinding(f) }
                fixTarget = nil
            }
            Button("Cancel", role: .cancel) { fixTarget = nil }
        } message: {
            Text("Claude edits files in this PR's worktree — a disposable checkout under Application Support, never your clone — and runs no commands. Nothing is committed or pushed; you review the patch afterwards.")
        }
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
        .onChange(of: session.data.verdict) { _, v in
            if v != nil { showRightPanel = true }
        }
    }
}

extension Notification.Name { static let difftCancelAgent = Notification.Name("difftCancelAgent") }

struct VerifyTab: View {
    /// Rough tool taxonomy so a long activity log stays scannable.
    static func icon(for tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Read", "NotebookEdit": return "doc.text"
        case "Edit", "Write": return "square.and.pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }

    @ObservedObject var session: ReviewSession
    @ObservedObject var controller: AgentController
    @State private var confirmShown = false
    // Decoded lazily and cached by URL: without this, `body` re-decodes every
    // (possibly multi-MB) screenshot on the main thread on every render —
    // and during verify, `controller.streamingText`/`toolActivity` changes
    // trigger a render on every stream delta.
    @State private var imageCache: [URL: NSImage] = [:]

    var body: some View {
        VStack(spacing: 8) {
            Button("Verify UI changes") { confirmShown = true }
                .disabled(!session.agentState.canStart)
                .confirmationDialog(
                    "Run PR code with permissions disabled?",
                    isPresented: $confirmShown, titleVisibility: .visible) {
                    Button("Run verification", role: .destructive) {
                        Task { await controller.runVerify(verifyConfirmed: true) }
                    }
                    .accessibilityLabel("Run verification")
                    Button("Cancel", role: .cancel) {}
                        .accessibilityLabel("Cancel verification")
                } message: {
                    Text("This runs the PR's code with Claude's permission checks disabled. " +
                         "Arbitrary code from PR #\(session.data.pr.number) ('\(session.data.pr.title)') will be able to " +
                         "execute on this machine. Only proceed if you trust this PR's author.")
                }

            if let verdict = session.data.verdict {
                Text("Verdict: \(verdict)").font(.headline)
                    .foregroundStyle(verdict == "pass" ? .green : verdict == "fail" ? .red : .orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    // Only this run's activity: another run's (review/clarify)
                    // log bleeding in here reads as stale garbage.
                    if controller.lastRunLabel == "Verifying" {
                        ForEach(controller.toolActivity) { call in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Image(systemName: Self.icon(for: call.name))
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(call.name).font(.caption.bold())
                                if let detail = call.detail {
                                    Text(detail)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                        .help(detail)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !controller.streamingText.isEmpty {
                            Text(controller.streamingText.suffix(2000))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else if case .running = session.agentState {
                        Text("Another agent task is running…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))]) {
                        ForEach(controller.evidence, id: \.self) { url in
                            if let img = imageCache[url] {
                                Image(nsImage: img).resizable().scaledToFit()
                                    .onTapGesture { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                }.padding(8)
            }
        }
        .padding(.top, 8)
        .safeAreaInset(edge: .bottom, spacing: 0) { AgentRunBar(session: session) }
        .task(id: controller.evidence) { refreshImageCache() }
    }

    /// Decodes only newly-seen evidence URLs and drops entries no longer
    /// present, so a body re-render never re-reads an already-decoded PNG.
    private func refreshImageCache() {
        var updated: [URL: NSImage] = [:]
        for url in controller.evidence {
            updated[url] = imageCache[url] ?? NSImage(contentsOf: url)
        }
        imageCache = updated
    }
}
