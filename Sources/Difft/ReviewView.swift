import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// Findings as their own centre pane.
///
/// They lived in the 300pt assistant panel, which could show a flat list and
/// nothing else — no counts, no severity filter, no way to dismiss one that is
/// wrong, and no sign of how old they were. A review is triage, and triage
/// needs width.
struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    @ObservedObject var controller: AgentController

    @State private var severityFilter: SeverityFilter = .all
    @State private var showDismissed = false
    @State private var fixTarget: Finding?

    enum SeverityFilter: String, CaseIterable, Identifiable {
        case all = "All", high = "High", medium = "Medium", low = "Low"
        var id: String { rawValue }
        func matches(_ f: Finding) -> Bool {
            self == .all || f.severity.lowercased() == rawValue.lowercased()
        }
    }

    private var findings: [Finding] { session.data.findings }
    private var visible: [Finding] {
        findings.filter { severityFilter.matches($0) && (showDismissed || !$0.dismissed) }
    }
    private var runningLabel: String? {
        if case .running(let label) = session.agentState { return label }
        return nil
    }

    /// A review pass specifically — it is what the empty pane waits on.
    private var isReviewing: Bool {
        runningLabel == "Reviewing" || runningLabel == "Verifying"
    }

    /// Any run started from this pane, "Fixing" included.
    ///
    /// Fix runs used to show nothing at all: the buttons greyed out, and
    /// minutes later the answer appeared in a chat panel that is hidden by
    /// default. There was also no way to stop one.
    private var isBusy: Bool { runningLabel != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .confirmationDialog("Let Claude edit files to fix this?",
                            isPresented: Binding(get: { fixTarget != nil },
                                                 set: { if !$0 { fixTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Write the fix") {
                if let f = fixTarget { Task { await controller.runFix(f) } }
                fixTarget = nil
            }
            Button("Cancel", role: .cancel) { fixTarget = nil }
        } message: {
            Text("Claude edits files in this PR's worktree — a disposable checkout under "
                 + "Application Support, never your clone — and runs no commands. Nothing is "
                 + "committed or pushed; you review the patch afterwards.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            PaneHeader {
                Text("Findings").font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
                if let stamp = session.data.reviewStamp {
                    Text(provenance(stamp))
                        .font(Typography.meta).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            } trailing: {
                if isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    if let label = runningLabel {
                        Text(label).font(Typography.control).foregroundStyle(Palette.textSecondary)
                    }
                    if let started = controller.runStartedAt { ElapsedLabel(start: started) }
                    Button("Stop") { controller.cancel() }.buttonStyle(SecondaryButtonStyle())
                } else if session.data.reviewStamp != nil {
                    Button {
                        Task { await model.review(force: true) }
                    } label: {
                        Label("Review again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!session.agentState.canStart)
                    .help("Review again against the current head")
                }
            }
            if !findings.isEmpty {
                HStack(spacing: Spacing.md) {
                    SegmentedControl(selection: $severityFilter,
                                     options: SeverityFilter.allCases.map { ($0, label(for: $0)) })
                    Spacer()
                    let dismissed = findings.count { $0.dismissed }
                    if dismissed > 0 {
                        Toggle("Show \(dismissed) dismissed", isOn: $showDismissed)
                            .toggleStyle(.checkbox).font(Typography.meta)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
        }
    }

    /// Counts live in the filter itself — a severity with nothing in it should
    /// say so rather than looking like an unexplored tab.
    private func label(for filter: SeverityFilter) -> String {
        let n = findings.filter { filter.matches($0) && !$0.dismissed }.count
        return filter == .all ? "All \(n)" : "\(filter.rawValue) \(n)"
    }

    private func provenance(_ s: ReviewStamp) -> String {
        var parts = [ExplainView.age(of: s.generatedAt)]
        if let sha = s.headSHA { parts.append(String(sha.prefix(7))) }
        if s.discarded > 0 { parts.append("\(s.discarded) rejected in review") }
        if let was = s.headSHA, let now = model.commits.first?.sha, was != now {
            parts.append("head has moved since")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Body

    @ViewBuilder private var content: some View {
        if isReviewing && findings.isEmpty {
            running
        } else if findings.isEmpty {
            empty
        } else if visible.isEmpty {
            ContentUnavailableView("Nothing at this severity", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Findings exist at other severities."))
        } else {
            list
        }
    }

    private var running: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
            Text(controller.lastRunLabel == "Verifying"
                 ? "Checking each finding against the code, discarding what it cannot prove…"
                 : "Reading the changed files and their callers…")
                .font(Typography.body).foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if !controller.toolActivity.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.toolActivity.suffix(6)) { call in
                        HStack(spacing: Spacing.xs) {
                            Text(call.name).font(.caption.bold())
                            if let detail = call.detail {
                                Text(detail).font(Typography.identifier)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: Spacing.md) {
            if session.data.reviewStamp != nil {
                // A clean review is a result, not an empty screen.
                ContentUnavailableView {
                    Label("No defects found", systemImage: "checkmark.seal")
                } description: {
                    Text(clearedDescription)
                }
            } else {
                ContentUnavailableView {
                    Label("No review yet", systemImage: "checklist")
                } description: {
                    Text("Claude reads the changed files, then a second pass tries to disprove "
                         + "each finding and throws out what it cannot show is real.")
                }
            }
            if case .failed(let message) = session.agentState {
                Text(message).font(Typography.meta).foregroundStyle(Palette.warning)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button {
                Task { await model.review(force: true) }
            } label: {
                Label(session.data.reviewStamp == nil ? "Review this PR" : "Review again",
                      systemImage: "checklist")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!session.agentState.canStart)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clearedDescription: String {
        guard let n = session.data.reviewStamp?.discarded, n > 0 else {
            return "Nothing was flagged in the changed code."
        }
        return "\(n) candidate\(n == 1 ? "" : "s") did not survive verification."
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.sm, pinnedViews: [.sectionHeaders]) {
                ForEach(byFile, id: \.path) { group in
                    Section {
                        ForEach(group.findings) { finding in
                            FindingCard(finding: finding,
                                        onOpen: { open(finding) },
                                        onFix: { fixTarget = finding },
                                        onDismiss: { model.setFindingDismissed(finding, !finding.dismissed) },
                                        canFix: session.agentState.canStart)
                        }
                    } header: {
                        fileHeader(group.path, count: group.findings.count)
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Grouped by file, files ordered by their worst finding — the file most
    /// worth opening comes first.
    private var byFile: [(path: String, findings: [Finding])] {
        Dictionary(grouping: visible, by: \.file)
            .map { (path: $0.key, findings: $0.value.sorted { $0.line < $1.line }) }
            .sorted {
                let a = $0.findings.map(\.severityRank).min() ?? 3
                let b = $1.findings.map(\.severityRank).min() ?? 3
                return a == b ? $0.path < $1.path : a < b
            }
    }

    private func fileHeader(_ path: String, count: Int) -> some View {
        let name = String(path.split(separator: "/").last ?? Substring(path))
        let dir = path.split(separator: "/").dropLast().joined(separator: "/")
        return HStack(spacing: Spacing.xs) {
            Image(systemName: "doc.text").imageScale(.small).foregroundStyle(Palette.textSecondary)
            Text(name).font(Typography.fileName)
            if !dir.isEmpty {
                Text(dir).font(Typography.path).foregroundStyle(Palette.textTertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Text("\(count)").font(Typography.badge).foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.canvas)
    }

    private func open(_ f: Finding) {
        session.selectedLines = f.line...f.line
        session.selectedFile = f.file
        session.pane = .diff
    }
}

/// One finding: what is wrong, the failure it produces, and what you can do
/// about it.
private struct FindingCard: View {
    let finding: Finding
    let onOpen: () -> Void
    let onFix: () -> Void
    let onDismiss: () -> Void
    let canFix: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                SeverityChip(severity: finding.severity)
                if !finding.category.isEmpty {
                    Text(finding.category)
                        .font(Typography.badge).foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.surfaceRaised, in: Capsule())
                }
                // Only the weaker verdict is worth a badge: everything here
                // survived verification, so "confirmed" is the norm.
                if finding.confidence == .plausible {
                    Label("unproven", systemImage: "questionmark.diamond")
                        .font(Typography.badge).foregroundStyle(Palette.warning)
                        .help("Real in the code, but reaching it depends on something "
                              + "outside this diff that could not be checked.")
                }
                Spacer(minLength: Spacing.xs)
                Button(action: onOpen) {
                    Text("\(String(finding.file.split(separator: "/").last ?? ""))" + ":\(finding.line)")
                        .font(Typography.identifier)
                }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
                .help("Open this line in the diff")
            }
            Text(finding.explanation)
                .font(Typography.body).foregroundStyle(Palette.text)
                .lineSpacing(Typography.bodyLineSpacing).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !finding.failureScenario.isEmpty {
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Image(systemName: "arrow.turn.down.right")
                        .imageScale(.small).foregroundStyle(Palette.textTertiary)
                    Text(finding.failureScenario)
                        .font(Typography.control).foregroundStyle(Palette.textSecondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Spacing.md) {
                Button("Fix it", action: onFix)
                    .buttonStyle(QuietButtonStyle()).disabled(!canFix)
                    .help("Have Claude write a fix in the PR worktree")
                Button(finding.dismissed ? "Restore" : "Dismiss", action: onDismiss)
                    .buttonStyle(QuietButtonStyle())
                Spacer()
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(finding.dismissed ? 0.5 : 1)
        .card()
        .contextMenu {
            Button("Open in Diff", action: onOpen)
            Button(finding.dismissed ? "Restore" : "Dismiss", action: onDismiss)
            Button("Fix It\u{2026}", action: onFix).disabled(!canFix)
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "[\(finding.severity)] \(finding.file):\(finding.line)\n\(finding.explanation)"
                    + (finding.failureScenario.isEmpty ? "" : "\n\(finding.failureScenario)"),
                    forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

struct SeverityChip: View {
    let severity: String

    static func color(for severity: String) -> Color {
        switch severity.lowercased() {
        case "high": return Palette.removedText
        case "medium": return Palette.amber
        default: return Palette.textSecondary
        }
    }

    var body: some View {
        Text(severity.uppercased())
            .font(.system(size: 10.5, weight: .bold)).kerning(0.5)
            .foregroundStyle(Self.color(for: severity))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Self.color(for: severity).opacity(0.15), in: Capsule())
    }
}

/// Live elapsed time for a running agent pass.
struct ElapsedLabel: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(start)))
                .font(Typography.metaDigits)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }
}
