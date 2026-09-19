import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// What stands between the reader and submitting a review.
///
/// The app knew all of this already — open threads, findings nobody had
/// dismissed, files nobody had opened — but kept each count in a different
/// pane, so "am I done?" meant visiting four of them. Here they are one list
/// that empties as it is worked through, and the way to finish sits under it.
struct QueueTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    /// The item last opened from here. Tracked locally because the diff
    /// clears `selectedLines` once it has scrolled to them.
    @State private var activeID: String?

    /// One thing to deal with, already described.
    struct Item: Identifiable {
        enum Kind { case thread(CommentThread), finding(Finding), unviewed }
        let id: String
        let kind: Kind
        let tint: Color
        let hollow: Bool
        let title: String
        let detail: String?
        let location: String
        let path: String?
    }

    var body: some View {
        let items = buildItems()
        let current = session.pane == .diff ? session.selectedFile : nil
        let here = items.filter { $0.path != nil && $0.path == current }
        let elsewhere = items.filter { $0.path == nil || $0.path != current }
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if items.isEmpty {
                        emptyState
                    } else if here.isEmpty {
                        group(nil, elsewhere)
                    } else {
                        group("In this file", here)
                        if !elsewhere.isEmpty { group("Elsewhere", elsewhere) }
                    }
                    reviewPrompt
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.md)
            }
            AgentRunBar(session: session)
            footer(queueEmpty: items.isEmpty)
        }
    }

    // MARK: - Items

    private func buildItems() -> [Item] {
        var items: [Item] = []
        for thread in model.threads where !thread.resolved {
            let count = thread.comments.count
            items.append(Item(
                id: "thread:\(thread.id)", kind: .thread(thread),
                tint: Palette.amber, hollow: false,
                title: "Open thread \u{00B7} \(thread.root.author)",
                detail: Self.firstLine(of: thread.root.body),
                location: Self.location(thread.path, thread.line)
                    + (count > 1 ? " \u{00B7} \(count) comments" : ""),
                path: thread.path))
        }
        let findings = session.data.findings.filter { !$0.dismissed }
            .sorted { $0.severityRank == $1.severityRank ? $0.file < $1.file : $0.severityRank < $1.severityRank }
        for finding in findings {
            items.append(Item(
                id: "finding:\(finding.id)", kind: .finding(finding),
                tint: SeverityChip.color(for: finding.severity), hollow: false,
                title: "\(finding.severity.capitalized) finding",
                detail: finding.explanation,
                location: Self.location(finding.file, finding.line),
                path: finding.file))
        }
        let unviewed = model.files.filter { !session.data.viewedFiles.contains($0.path) }
        if !unviewed.isEmpty {
            let lines = unviewed.reduce(0) { $0 + $1.additions + $1.deletions }
            items.append(Item(
                id: "unviewed", kind: .unviewed,
                tint: Palette.textTertiary, hollow: true,
                title: "\(unviewed.count) file\(unviewed.count == 1 ? "" : "s") not viewed",
                detail: nil,
                location: "\(lines.formatted()) changed line\(lines == 1 ? "" : "s")",
                path: nil))
        }
        return items
    }

    private static func location(_ path: String, _ line: Int?) -> String {
        // Two trailing components: "main.py" alone is ambiguous in any repo
        // with more than one package.
        let short = path.split(separator: "/").suffix(2).joined(separator: "/")
        return line.map { "\(short):\($0)" } ?? short
    }

    /// The first line of a comment that says something, as plain text.
    ///
    /// Review bots open with HTML badges and numbered headings, so tags,
    /// markdown escapes and list markers are stripped before choosing.
    static func firstLine(of body: String) -> String {
        // The queue re-renders on every file switch; without this each open
        // thread cost four regular expressions per render.
        let key = body as NSString
        if let hit = previewCache.object(forKey: key) { return hit as String }
        let line = computeFirstLine(of: body)
        previewCache.setObject(line as NSString, forKey: key)
        return line
    }

    private static let previewCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()

    private static func computeFirstLine(of body: String) -> String {
        // Badges first: their alt text ("Action required") would otherwise
        // be the first line of every bot comment.
        let unbadged = body.replacingOccurrences(of: "<img\\b[^>]*>", with: "",
                                                 options: [.regularExpression, .caseInsensitive])
        let plain = CommentHTML.markdown(from: unbadged)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "[`*]", with: "", options: .regularExpression)
        let line = plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.contains(where: \.isLetter) } ?? ""
        return line
            .replacingOccurrences(of: "^(#+|[-*>]|\\d+[.)])\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
    }

    @ViewBuilder private func group(_ title: String?, _ items: [Item]) -> some View {
        if let title {
            Text(title.uppercased())
                .font(Typography.eyebrow).kerning(0.6)
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, Spacing.sm + 2)
                .padding(.top, Spacing.sm).padding(.bottom, Spacing.xs)
        }
        ForEach(items) { item in
            QueueRow(item: item, isCurrent: isCurrent(item)) { open(item) }
                .contextMenu { menu(for: item) }
        }
    }

    private func isCurrent(_ item: Item) -> Bool {
        item.id == activeID && session.pane == .diff && item.path == session.selectedFile
    }

    private func open(_ item: Item) {
        activeID = item.id
        switch item.kind {
        case .thread(let thread): model.open(file: thread.path, line: thread.line)
        case .finding(let finding): model.open(file: finding.file, line: finding.line)
        case .unviewed:
            if let next = model.firstUnviewed(after: session.selectedFile) { model.open(file: next) }
        }
    }

    @ViewBuilder private func menu(for item: Item) -> some View {
        switch item.kind {
        case .thread(let thread):
            Button("Open in Diff") { open(item) }
            if thread.root.threadID != nil {
                Button("Resolve Thread") { Task { await model.resolve(thread.root) } }
            }
            Divider()
            Button("Copy Comment") { AppModel.copy(thread.root.body) }
        case .finding(let finding):
            Button("Open in Diff") { open(item) }
            Button("Dismiss Finding") { model.setFindingDismissed(finding, true) }
            Divider()
            Button("Copy Finding") {
                AppModel.copy("[\(finding.severity)] \(finding.file):\(finding.line)\n\(finding.explanation)")
            }
        case .unviewed:
            Button("Open Next Unviewed File") { open(item) }
            Button("Mark All Files Viewed") {
                for file in model.files { model.markViewed(file.path, viewed: true) }
            }
        }
    }

    // MARK: - Edges

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.added)
            Text("Nothing left in the queue")
                .font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
            Text("Every file viewed, no open threads, no findings waiting.")
                .font(Typography.control).foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xl)
    }

    /// Offered, never run on sight: a review is a couple of minutes of agent.
    @ViewBuilder private var reviewPrompt: some View {
        if session.data.reviewStamp == nil, session.agentState.canStart {
            Button { Task { await model.review() } } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "sparkles").font(.system(size: 11.5))
                    Text("Have Claude review this PR")
                    Spacer(minLength: 0)
                }
                .font(Typography.control)
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, Spacing.sm + 2)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.sm)
            .help("Two passes: find candidates, then try to disprove each one. "
                  + "What survives joins this queue.")
        }
    }

    private func footer(queueEmpty: Bool) -> some View {
        let drafts = session.data.draftComments.count
        return VStack(alignment: .leading, spacing: Spacing.sm + 2) {
            (Text("Your review").fontWeight(.semibold).foregroundColor(Palette.textStrong)
             + Text(drafts == 0
                    ? " \u{00B7} no notes yet. Nothing is sent until you finish."
                    : " \u{00B7} \(drafts) note\(drafts == 1 ? "" : "s") staged. Nothing is sent until you finish."))
                .font(Typography.control)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.closeCommit()
                session.pane = .pending
            } label: {
                Text("Finish review\u{2026}").frame(maxWidth: .infinity)
            }
            // Filled only once the queue is clear, so while there is reading
            // left the one loud button on screen is Mark viewed.
            .buttonStyle(FinishButtonStyle(filled: queueEmpty))
            .help("Write a summary, pick a verdict, and submit your notes together (\u{21E7}\u{2318}Y)")
        }
        .padding(Spacing.lg)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

private struct FinishButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? Palette.onAccent : Palette.accent)
            .frame(height: 32)
            .background(filled ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.accent.opacity(filled ? 0 : 0.55))
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

private struct QueueRow: View {
    let item: QueueTab.Item
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.sm + 2) {
                Circle()
                    .fill(item.hollow ? .clear : item.tint)
                    .overlay { if item.hollow { Circle().strokeBorder(item.tint, lineWidth: 1.5) } }
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.textStrong)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(Typography.control)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(item.location)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.sm + 2)
            .padding(.vertical, Spacing.sm)
            .background(isCurrent ? Palette.selection : (hovering ? Palette.hover : .clear),
                        in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Palette.selectionBorder)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
