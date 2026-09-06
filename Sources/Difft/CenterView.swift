import SwiftUI
import DifftCore
import DifftServices
import DifftUI

struct CenterView: View {
    @EnvironmentObject var model: AppModel
    var onAsk: (String, String) -> Void

    var body: some View {
        if let session = model.session {
            // Observed directly by FileDiffContainer (not just AppModel) per Task 13
            // controller ruling #2 — session.selectedFile mutations (e.g. from the sidebar's
            // file list, or j/k stepping below) wouldn't otherwise trigger a re-render of a
            // view observing only AppModel, since ReviewSession is a nested ObservableObject.
            FileDiffContainer(session: session, onAsk: onAsk)
        } else {
            ContentUnavailableView("Pick a PR", systemImage: "arrow.triangle.pull")
        }
    }
}

/// The way back to the PR overview, in the leading position of every
/// centre-pane header. A bare xmark on the trailing edge read as "dismiss"
/// rather than "go up a level", so it says where it goes.
struct OverviewBackButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.showOverview()
        } label: {
            Label("Overview", systemImage: "chevron.left").font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help("Back to the pull request overview (\u{2318}0)")
        .accessibilityLabel("Back to pull request overview")
    }
}

/// Slim header above an open file's diff: name, directory, counts, and the
/// way back to the PR overview.
struct FileHeaderBar: View {
    let file: FileDiff
    var isRefreshing: Bool = false
    var onRefresh: () -> Void = {}
    var onClose: () -> Void

    var body: some View {
        let name = String(file.path.split(separator: "/").last ?? "")
        let dir = file.path.split(separator: "/").dropLast().joined(separator: "/")
        HStack(spacing: 8) {
            OverviewBackButton()
            Divider().frame(height: 14)
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(name).font(Typography.fileName)
            if !dir.isEmpty {
                Text(dir)
                    .font(Typography.path)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("+\(file.additions)").foregroundStyle(.green).font(.caption.monospacedDigit())
            Text("−\(file.deletions)").foregroundStyle(.red).font(.caption.monospacedDigit())
            Button {
                onRefresh()
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .help("Fetch new commits and reload comments (⌘R)")
            .accessibilityLabel("Refresh pull request")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// IntelliJ-style PR landing page: title, meta, markdown description, and an
/// AI explain action — shown while no file is selected.
struct PROverviewView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    @AppStorage("showRightPanel") private var showRightPanel = false
    @AppStorage("rightPanelTab") private var panelTab = 0

    var body: some View {
        let pr = session.data.pr
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(pr.title)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Text(verbatim: "#\(String(pr.number))")
                        .font(.callout.monospacedDigit().bold())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    Label(pr.authorLogin, systemImage: "person")
                    Label(pr.headRefName, systemImage: "arrow.triangle.branch")
                        .font(.callout.monospaced())
                    if let base = pr.baseRefName {
                        Image(systemName: "arrow.right")
                        Text(base).font(.callout.monospaced())
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(model.files.count) files", systemImage: "doc.on.doc")
                    Text(verbatim: "+\(String(model.files.reduce(0) { $0 + $1.additions }))")
                        .foregroundStyle(.green).monospacedDigit()
                    Text(verbatim: "−\(String(model.files.reduce(0) { $0 + $1.deletions }))")
                        .foregroundStyle(.red).monospacedDigit()
                    CommentsButton(session: session)
                    CommitsButton(session: session)
                    FindingsButton(session: session)
                    Spacer()
                    if let note = model.refreshNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Button {
                        Task { await model.refreshPR() }
                    } label: {
                        if model.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isRefreshing)
                    .help("Fetch new commits and reload comments (⌘R)")
                    .accessibilityLabel("Refresh pull request")
                    Button {
                        Task { await model.explainDiff() }
                    } label: {
                        // Says which it is: running the agent costs a couple of
                        // minutes, opening a cached walkthrough is instant, and
                        // one label for both hid that difference.
                        Label(session.data.explanation == nil ? "Explain diff" : "Walkthrough",
                              systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.agentState.canStart && session.data.explanation == nil)
                    .help(session.data.explanation == nil
                          ? "Read the PR and explain it (\u{21E7}\u{2318}E)"
                          : "Open the PR walkthrough (\u{21E7}\u{2318}E)")
                }
                .font(.callout)
                Divider()
                if pr.body.isEmpty {
                    Text("No description.")
                        .foregroundStyle(.tertiary)
                } else {
                    MarkdownBodyView(text: pr.body)
                }
                // Work already done on this PR, surfaced where you land rather
                // than left behind two keystrokes away. Nothing shows until
                // there is something to show, so the page does not grow chrome
                // for a PR you have not touched.
                OverviewDigest(session: session)
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FileDiffContainer: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    @State private var layout: DiffLayout = .sideBySide
    @State private var selection: LineSelection?
    @AppStorage(PrefKey.diffFontSize) private var fontSize = DiffMetrics.defaultFontSize
    var onAsk: (String, String) -> Void

    var body: some View {
        switch session.pane {
        case .commits:
            if let commit = session.selectedCommit {
                CommitDiffView(session: session, commit: commit, onAsk: onAsk)
            } else {
                PRCommitsView(session: session)
            }
        case .comments:
            PRCommentsView(session: session)
        case .explain:
            ExplainView(session: session, controller: model.agent)
        case .review:
            ReviewView(session: session, controller: model.agent)
        case .diff:
            diffOrOverview
        }
    }

    @ViewBuilder private var diffOrOverview: some View {
        if let path = session.selectedFile,
           let file = model.files.first(where: { $0.path == path }) {
            VStack(spacing: 0) {
                FileHeaderBar(file: file,
                              isRefreshing: model.isRefreshing,
                              onRefresh: { Task { await model.refreshPR() } },
                              onClose: { session.selectedFile = nil })
                FileDiffView(file: file, layout: $layout, selection: $selection, fontSize: fontSize,
                         focusLine: session.selectedLines?.lowerBound,
                         comments: model.commentsByPath[file.path] ?? [],
                         findings: session.data.findings.filter { $0.file == file.path },
                         onFocused: { session.selectedLines = nil },
                         onAsk: onAsk,
                         onReplyComment: { c, body in Task { await model.reply(to: c, body: body) } },
                         onResolveComment: { c in Task { await model.resolve(c) } },
                         onEditComment: { c in
                             // No handler means no Edit button, which is how
                             // someone else's comment shows no action that
                             // would only fail.
                             guard model.canEdit(c) else { return nil }
                             return { body in Task { await model.edit(c, body: body) } }
                         },
                         onAddComment: { start, end, body in
                             Task { await model.addComment(path: file.path, startLine: start,
                                                           endLine: end, body: body) }
                         })
            }
                .id(file.path) // reset scroll + selection per file
                .onChange(of: file.path) { selection = nil }
                .focusable()
                .focusEffectDisabled()  // no blue focus ring around the diff
                .onKeyPress("j") { step(1); return .handled }
                .onKeyPress("k") { step(-1); return .handled }
                .toolbar {
                    Picker("Layout", selection: $layout) {
                        ForEach(DiffLayout.allCases, id: \.self) { Text($0.rawValue) }
                    }.pickerStyle(.segmented)
                    Stepper("Font \(fontSize)pt", value: $fontSize,
                            in: DiffMetrics.minFontSize...DiffMetrics.maxFontSize)
                }
        } else {
            PROverviewView(session: session)
        }
    }

    private func step(_ delta: Int) {
        guard let current = session.selectedFile,
              let idx = model.files.firstIndex(where: { $0.path == current }) else {
            if delta > 0 { session.selectedFile = model.files.first?.path }
            return
        }
        let next = idx + delta
        if model.files.indices.contains(next) { session.selectedFile = model.files[next].path }
    }
}

struct MainSplitView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingAsk: (text: String, chip: String)?
    // Hidden by default: the diff is the workspace, the assistant is an
    // inspector. Auto-opens when the user asks about a selection or when
    // findings arrive (see AgentStatusView).
    @AppStorage("showRightPanel") private var showRightPanel = false

    @AppStorage("rightPanelTab") private var panelTab = 0

    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            // Diff pane must absorb extra width; NavigationSplitView's detail column
            // is the only greedy one, so both panes live there split by HSplitView
            // with the chat panel capped. The tool strip (IntelliJ-style) stays
            // pinned at the window edge whether or not the panel is open.
            HStack(spacing: 0) {
                HSplitView {
                    VStack(spacing: 0) {
                        if let banner = model.errorBanner {
                            Text(banner).foregroundStyle(Color.white).padding(Spacing.sm - 2)
                                .frame(maxWidth: .infinity).background(.red)
                        }
                        CenterView { text, chip in
                            pendingAsk = (text, chip)
                            panelTab = 0
                            showRightPanel = true
                        }
                        StatusBar()
                    }
                    .frame(minWidth: 480, maxWidth: .infinity)
                    .layoutPriority(1)
                    // Without a session the panel has nothing to show and its
                    // collapsed content left a floating divider fragment.
                    if showRightPanel, model.session != nil {
                        RightPanel(pendingAsk: $pendingAsk, tab: $panelTab)
                            .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
                    }
                }
                Divider()
                ToolStrip(showPanel: $showRightPanel, tab: $panelTab,
                          onReport: generateReport, onClean: cleanWorktrees)
            }
            // ⌥⌘0 still toggles the panel; the visible toggle lives in the strip.
            .background(
                ZStack {
                    Button("") { showRightPanel.toggle() }
                        .keyboardShortcut("0", modifiers: [.option, .command])
                }
                .hidden()
            )
        }
    }

    private func generateReport() {
        Task {
            do {
                let url = try await model.generateReport()
                NSWorkspace.shared.open(url)
                model.errorBanner = nil
            } catch {
                model.errorBanner = "Failed to generate report: \(error.localizedDescription)"
            }
        }
    }

    private func cleanWorktrees() {
        let baseDir = AppModel.appSupportDir.appendingPathComponent("worktrees")
        Task.detached(priority: .utility) {
            try? WorktreeManager(runner: DefaultProcessRunner(), baseDir: baseDir)
                .prune(olderThan: 0)
        }
    }
}

/// IntelliJ-style vertical tool-window strip: one icon per assistant tab,
/// always visible at the window's right edge. Clicking a tab opens the panel
/// on it; clicking the active tab again collapses the panel.
struct ToolStrip: View {
    @EnvironmentObject var model: AppModel
    @Binding var showPanel: Bool
    @Binding var tab: Int
    var onReport: () -> Void = {}
    var onClean: () -> Void = {}

    private let items: [(icon: String, label: String)] = [
        ("bubble.left.and.text.bubble.right", "Claude"),
        ("checklist", "Findings"),
    ]

    var body: some View {
        // The assistant panel only exists with a PR open, so its tabs must
        // read as unavailable until then — they used to look active and
        // highlighted while clicking did nothing.
        let enabled = model.session != nil
        VStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                let active = enabled && showPanel && tab == i
                Button {
                    if showPanel && tab == i {
                        showPanel = false
                    } else {
                        tab = i
                        showPanel = true
                    }
                } label: {
                    Image(systemName: items[i].icon)
                        .imageScale(.medium)
                        .frame(width: 28, height: 28)
                        .background(active ? Color.accentColor.opacity(0.25) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(active ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
                .help(enabled ? items[i].label : "\(items[i].label) — open a pull request first")
                .accessibilityLabel("\(items[i].label) panel")
            }
            Spacer()
            Divider().frame(width: 20)
            Button {
                onReport()
            } label: {
                Image(systemName: "doc.richtext")
                    .imageScale(.medium)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.session == nil)
            .opacity(model.session == nil ? 0.35 : 1)
            .help(model.session == nil
                  ? "Generate HTML report — open a pull request first"
                  : "Generate HTML report and open it")
            .accessibilityLabel("Generate report")
            Button {
                onClean()
            } label: {
                Image(systemName: "folder.badge.minus")
                    .imageScale(.medium)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete all Difft worktree checkouts")
            .accessibilityLabel("Clean worktrees")
        }
        .padding(.vertical, 10)
        .frame(width: 36)
        .background(.bar)
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            if let s = model.session {
                Text(verbatim: "#\(String(s.data.pr.number)) \(s.data.pr.title)").lineLimit(1)
                Text(s.data.pr.headRefName).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            // AgentStatusView observes ReviewSession directly (project ruling #2) so it
            // must be handed a concrete session rather than reading model.session? itself.
            if let s = model.session {
                AgentStatusView(session: s)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
    }
}

/// Opens the all-comments list from the PR overview, showing how many threads
/// are waiting and how many of those are still unresolved.
struct CommentsButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession

    var body: some View {
        // Comments arrive after the diff now, so a bare "0" while they are
        // still in flight would be a wrong answer rather than a pending one.
        if model.isLoadingDetails {
            ProgressView().controlSize(.small)
        } else {
            let threads = CommentThread.group(model.comments)
            let unresolved = threads.count { !$0.resolved }
            Button {
                model.closeCommit()
                session.pane = .comments
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(verbatim: "\(threads.count)")
                        .monospacedDigit()
                    if unresolved > 0 {
                        Text(verbatim: "(\(unresolved) unresolved)")
                            .foregroundStyle(Palette.warning)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(threads.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .disabled(threads.isEmpty)
            .help(threads.isEmpty
                  ? "No review comments on this pull request"
                  : "Show all review comments (⇧⌘C)")
            .accessibilityLabel("Show all review comments")
        }
    }
}

/// The walkthrough's opening paragraph and the worst findings, if either
/// exists — the overview had two-thirds of a tall window doing nothing, and
/// this is the state a reviewer returning to a PR actually wants.
struct OverviewDigest: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession

    private var openFindings: [Finding] {
        session.data.findings
            .filter { !$0.dismissed }
            .sorted { $0.severityRank == $1.severityRank ? $0.file < $1.file : $0.severityRank < $1.severityRank }
    }

    var body: some View {
        let explanation = session.data.explanation
        let findings = openFindings
        if explanation != nil || !findings.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Divider()
                if let e = explanation, !e.summary.isEmpty {
                    card(title: "Walkthrough", systemImage: "sparkles",
                         action: "Open", onOpen: { Task { await model.explainDiff() } }) {
                        Text(e.summary)
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !findings.isEmpty {
                    card(title: "Findings", systemImage: "checklist",
                         action: findings.count > 3 ? "All \(findings.count)" : "Open",
                         onOpen: { Task { await model.review() } }) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(findings.prefix(3)) { finding in
                                Button {
                                    session.selectedLines = finding.line...finding.line
                                    session.selectedFile = finding.file
                                    session.pane = .diff
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                                        SeverityChip(severity: finding.severity)
                                        Text(finding.explanation)
                                            .font(Typography.body)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open \(finding.file):\(finding.line)")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func card<Content: View>(
        title: String, systemImage: String, action: String,
        onOpen: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: systemImage).imageScale(.small)
                Text(title)
                Spacer()
                Button(action, action: onOpen)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.callout)
            }
            .font(Typography.sectionTitle)
            .foregroundStyle(.secondary)
            content()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Palette.cardBorder)
                .allowsHitTesting(false)
        }
    }
}

/// Review state beside the comment and commit counts, so the pane has a way in
/// from the page you land on rather than only the View menu and the side panel.
struct FindingsButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession

    var body: some View {
        let open = session.data.findings.filter { !$0.dismissed }
        let reviewed = session.data.reviewStamp != nil
        Button {
            Task { await model.review() }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: reviewed && open.isEmpty ? "checkmark.seal" : "checklist")
                if reviewed {
                    Text(verbatim: open.isEmpty ? "clean" : "\(open.count)")
                        .monospacedDigit()
                    if let worst = open.map(\.severityRank).min(), worst == 0 {
                        Text("high").foregroundStyle(Palette.removed)
                    }
                } else {
                    Text("Review")
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(reviewed && open.isEmpty
                         ? AnyShapeStyle(Palette.added) : AnyShapeStyle(.secondary))
        .disabled(!session.agentState.canStart && !reviewed)
        .help(reviewed ? "Show review findings (\u{21E7}\u{2318}F)"
                       : "Review this pull request (\u{21E7}\u{2318}F)")
        .accessibilityLabel(reviewed ? "Show review findings" : "Review this pull request")
    }
}

struct CommitsButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession

    var body: some View {
        if model.isLoadingDetails {
            ProgressView().controlSize(.small)
        } else {
            Button {
                // Land on the list, not on whichever commit was open last.
                model.closeCommit()
                session.pane = .commits
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(verbatim: "\(model.commits.count)").monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.commits.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .disabled(model.commits.isEmpty)
            .help(model.commits.isEmpty
                  ? "No commits on this pull request"
                  : "Show all commits (⇧⌘K)")
            .accessibilityLabel("Show all commits")
        }
    }
}
