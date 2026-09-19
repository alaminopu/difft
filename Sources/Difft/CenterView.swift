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
        } else if model.repoDir == nil {
            HomeView()
        } else {
            PullRequestsView()
        }
    }
}

/// Header above an open file's diff: where it is, how big the change is, how
/// to move on, and the one thing you do to a file — mark it viewed.
struct FileHeaderBar: View {
    @EnvironmentObject var model: AppModel
    let file: FileDiff
    @ObservedObject var session: ReviewSession
    @Binding var layout: DiffLayout

    var body: some View {
        let parts = file.path.split(separator: "/").map(String.init)
        let index = model.files.firstIndex { $0.path == file.path } ?? 0
        let isViewed = session.data.viewedFiles.contains(file.path)
        PaneHeader {
            // One Text, so a long path truncates once at the head instead of
            // each segment losing its own middle.
            (Text(parts.dropLast().map { $0 + " / " }.joined()).foregroundColor(Palette.textTertiary)
             + Text(parts.last ?? "").fontWeight(.medium).foregroundColor(Palette.textStrong))
            .font(.system(size: 12.5, design: .monospaced))
            .lineLimit(1).truncationMode(.head)
            .layoutPriority(-1)
            .contextMenu { FileMenu(file: file, isViewed: isViewed) }
            if case .renamed(let from) = file.kind {
                Text("renamed from \(from)")
                    .font(Typography.meta).foregroundStyle(Palette.textTertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            HStack(spacing: 6) {
                Text("+\(file.additions)").foregroundStyle(Palette.addedText)
                Text("\u{2212}\(file.deletions)").foregroundStyle(Palette.removedText)
            }
            .font(.system(size: 12, design: .monospaced))
            .fixedSize()
        } trailing: {
            Text("\(index + 1) of \(model.files.count)")
                .font(Typography.metaDigits).foregroundStyle(Palette.textTertiary)
                .fixedSize()
            HStack(spacing: 0) {
                stepButton("chevron.up", help: "Previous file (K)", enabled: index > 0) {
                    model.stepFile(-1)
                }
                Rectangle().fill(Palette.cardBorder).frame(width: 1, height: 26)
                stepButton("chevron.down", help: "Next file (J)",
                           enabled: index < model.files.count - 1) { model.stepFile(1) }
            }
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.cardBorder) }
            SegmentedControl(selection: $layout,
                             options: [(.sideBySide, "Split"), (.unified, "Unified")])
            if isViewed {
                Button { model.markViewed(file.path, viewed: false) } label: {
                    Label("Viewed", systemImage: "checkmark")
                }
                .buttonStyle(SecondaryButtonStyle(tint: Palette.addedText))
                .help("Mark as not viewed (V)")
            } else {
                Button("Mark viewed") { model.toggleViewedAndAdvance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Mark this file viewed and open the next one (V)")
            }
        }
    }

    private func stepButton(_ icon: String, help: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The page a pull request opens on: what it is, what state it is in, and the
/// way into reading it.
struct PROverviewView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession

    var body: some View {
        let pr = session.data.pr
        let viewed = model.files.count { session.data.viewedFiles.contains($0.path) }
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(pr.title)
                        .font(Typography.pageTitle)
                        .foregroundStyle(Palette.textStrong)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Spacing.sm) {
                        stateTag(pr)
                        Text(verbatim: "#\(pr.number)").foregroundStyle(Palette.textSecondary)
                        AvatarDisc(login: pr.authorLogin, size: 18)
                        Text(pr.authorLogin).foregroundStyle(Palette.text)
                        Text("wants to merge").foregroundStyle(Palette.textTertiary)
                        Text(pr.headRefName).font(Typography.identifier)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                        if let base = pr.baseRefName {
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.textTertiary)
                            Text(base).font(Typography.identifier)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .font(Typography.body)
                }

                HStack(spacing: Spacing.md) {
                    Button(viewed == 0 ? "Start review" : viewed == model.files.count
                           ? "Open files" : "Continue review") { model.showFiles() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.files.isEmpty)
                        .help("Open the first file you have not viewed")
                    Button {
                        Task { await model.explainDiff() }
                    } label: {
                        // Says which it is: running the agent costs a couple of
                        // minutes, opening a cached walkthrough is instant, and
                        // one label for both hid that difference.
                        Label(session.data.explanation == nil ? "Explain this PR" : "Walkthrough",
                              systemImage: "sparkles")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!session.agentState.canStart && session.data.explanation == nil)
                    .help(session.data.explanation == nil
                          ? "Have Claude read the PR and explain it (\u{21E7}\u{2318}E)"
                          : "Open the PR walkthrough (\u{21E7}\u{2318}E)")
                    Button {
                        Task { await model.refreshPR() }
                    } label: {
                        if model.isRefreshing {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isRefreshing)
                    .help("Fetch new commits and reload comments (\u{2318}R)")
                    Spacer(minLength: 0)
                    VerdictChips()
                }

                facts(viewed: viewed)

                VStack(alignment: .leading, spacing: Spacing.md) {
                    if pr.body.isEmpty {
                        Text("No description.").font(Typography.body)
                            .foregroundStyle(Palette.textTertiary)
                    } else {
                        MarkdownBodyView(text: pr.body)
                    }
                }
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .contextMenu {
                    Button("Copy Description") { AppModel.copy(pr.body) }
                    if let url = model.pullRequestURL(number: pr.number) {
                        Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                    }
                }

                // Work already done on this PR, surfaced where you land rather
                // than left behind two keystrokes away. Nothing shows until
                // there is something to show.
                OverviewDigest(session: session)
            }
            // Prose is unreadable edge to edge; cap the measure and centre it.
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Palette.canvas)
    }

    private func stateTag(_ pr: PullRequest) -> Tag {
        if !pr.isOpen {
            return Tag(pr.stateLabel.capitalized,
                       tint: pr.stateLabel == "MERGED" ? .purple : Palette.removedText)
        }
        return pr.isDraft == true ? Tag("Draft", tint: Palette.textSecondary)
                                  : Tag("Open", tint: Palette.addedText)
    }

    /// The numbers, as a row of small tiles that lead where they point.
    private func facts(viewed: Int) -> some View {
        let additions = model.files.reduce(0) { $0 + $1.additions }
        let deletions = model.files.reduce(0) { $0 + $1.deletions }
        let open = session.data.findings.filter { !$0.dismissed }
        let hasHigh = open.contains { $0.severityRank == 0 }
        let reviewed = session.data.reviewStamp != nil
        let unresolved = model.unresolvedThreadCount
        return HStack(spacing: Spacing.md) {
            FactTile(label: "Files", value: "\(model.files.count)",
                     detail: Text("+\(additions.formatted())").foregroundColor(Palette.addedText)
                         + Text("  \u{2212}\(deletions.formatted())").foregroundColor(Palette.removedText)) {
                model.showFiles()
            }
            FactTile(label: "Viewed", value: "\(viewed) of \(model.files.count)",
                     detail: Text(viewed == model.files.count && viewed > 0
                                  ? "all read" : "\(model.files.count - viewed) left")) {
                model.showFiles()
            }
            FactTile(label: "Threads",
                     value: model.isLoadingDetails ? "\u{2026}" : "\(model.threads.count)",
                     detail: Text(unresolved > 0 ? "\(unresolved) open" : "none open")
                         .foregroundColor(unresolved > 0 ? Palette.amber : Palette.textTertiary)) {
                model.show(.threads)
            }
            FactTile(label: "Findings",
                     value: reviewed ? "\(open.count)" : "\u{2013}",
                     detail: Text(!reviewed ? "not reviewed" : open.isEmpty ? "clean"
                                  : hasHigh ? "high severity" : "to triage")
                         .foregroundColor(hasHigh ? Palette.removedText : Palette.textTertiary)) {
                model.show(.findings)
            }
            FactTile(label: "Commits",
                     value: model.isLoadingDetails ? "\u{2026}" : "\(model.commits.count)",
                     detail: Text(model.commits.first.map { Dates.age(iso: $0.date) } ?? " ")) {
                model.show(.commits)
            }
        }
    }
}

private struct FactTile: View {
    let label: String
    let value: String
    let detail: Text
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased()).font(Typography.eyebrow).kerning(0.6)
                    .foregroundStyle(Palette.textTertiary)
                Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.textStrong)
                detail.font(Typography.metaDigits).foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(border: hovering ? Palette.selectionBorder : Palette.cardBorder)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct FileDiffContainer: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    @AppStorage(PrefKey.diffLayout) private var layout: DiffLayout = .sideBySide
    @State private var selection: LineSelection?
    @State private var command: DiffCommand?
    @AppStorage(PrefKey.diffFontSize) private var fontSize = DiffMetrics.defaultFontSize
    var onAsk: (String, String) -> Void

    var body: some View {
        Group {
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
            case .pending:
                PendingReviewView(session: session)
            case .diff:
                diffOrOverview
            }
        }
        .background(Palette.canvas)
    }

    @ViewBuilder private var diffOrOverview: some View {
        if let path = session.selectedFile,
           let file = model.files.first(where: { $0.path == path }) {
            VStack(spacing: 0) {
                FileHeaderBar(file: file, session: session, layout: $layout)
                FileDiffView(file: file, layout: $layout, selection: $selection, fontSize: fontSize,
                         focusLine: session.selectedLines?.lowerBound,
                         comments: model.commentsByPath[file.path] ?? [],
                         findings: session.data.findings.filter { $0.file == file.path },
                         command: $command,
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
                         },
                         onStageComment: { start, end, body in
                             model.stageComment(path: file.path, startLine: start,
                                                endLine: end, body: body)
                         },
                         onDismissFinding: { model.setFindingDismissed($0, true) },
                         stagedCount: session.data.draftComments.count)
            }
                .id(file.path) // reset scroll + selection per file
                .onChange(of: file.path) { selection = nil }
                .focusable()
                .focusEffectDisabled()  // no blue focus ring around the diff
                .onKeyPress("j") { model.stepFile(1); return .handled }
                .onKeyPress("k") { model.stepFile(-1); return .handled }
                .onKeyPress("v") { model.toggleViewedAndAdvance(); return .handled }
                .onKeyPress("n") { command = DiffCommand(.nextChange); return .handled }
                .onKeyPress("p") { command = DiffCommand(.previousChange); return .handled }
                .onKeyPress("c") { command = DiffCommand(.comment); return .handled }
                .onKeyPress("a") { command = DiffCommand(.ask); return .handled }
        } else {
            PROverviewView(session: session)
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
                            .foregroundStyle(Palette.textSecondary)
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
                                            .foregroundStyle(Palette.textSecondary)
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
                    .foregroundStyle(Palette.accent)
                    .font(Typography.body)
            }
            .font(Typography.sectionTitle)
            .foregroundStyle(Palette.textSecondary)
            content()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Palette.cardBorder)
                .allowsHitTesting(false)
        }
    }
}

/// Review state beside the comment and commit counts, so the pane has a way in
/// from the page you land on rather than only the View menu and the side panel.
/// Whether anyone has approved or blocked the PR.
///
/// These verdicts live at `pulls/{n}/reviews`, separate from the inline notes
/// the app already showed — so "someone requested changes" was the one thing
/// about a pull request Difft could not tell you.
struct VerdictChips: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let tally = ReviewTally.of(model.reviews)
        HStack(spacing: Spacing.xs) {
            if tally.blocking > 0 {
                chip("\(tally.blocking) blocking", "xmark.octagon", .red)
            }
            if tally.approvals > 0 {
                chip("\(tally.approvals) approved", "checkmark.seal", .green)
            }
        }
    }

    private func chip(_ text: String, _ icon: String, _ tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xs + 1)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
