import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// Every review comment on the PR in one place, grouped by file.
///
/// The diff view answers "what did people say about this line"; this answers
/// "what has been said at all", which is the question you have before you know
/// which file to open.
struct PRCommentsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case unresolved = "Unresolved"
        case resolved = "Resolved"
        var id: Self { self }
    }

    @State private var filter: Filter = .all
    @State private var search = ""

    private var threads: [CommentThread] { model.threads }

    private var visibleThreads: [CommentThread] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        return threads.filter { thread in
            switch filter {
            case .all: break
            case .unresolved: if thread.resolved { return false }
            case .resolved: if !thread.resolved { return false }
            }
            guard !term.isEmpty else { return true }
            return thread.path.lowercased().contains(term)
                || thread.comments.contains {
                    $0.body.lowercased().contains(term) || $0.author.lowercased().contains(term)
                }
        }
    }

    /// File path with its threads, in the order `CommentThread.group` sorted
    /// them, so the list matches the file tree's ordering.
    private func byFile(_ visible: [CommentThread]) -> [(path: String, threads: [CommentThread])] {
        var order: [String] = []
        var grouped: [String: [CommentThread]] = [:]
        for thread in visible {
            if grouped[thread.path] == nil { order.append(thread.path) }
            grouped[thread.path, default: []].append(thread)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        // Bound once. As a computed property this ran four times per pass, and
        // each run lowercases every comment body on the PR — so every
        // keystroke in the search field walked the whole corpus four times.
        let visible = visibleThreads
        VStack(spacing: 0) {
            header
            // Verdicts first: whether the PR is blocked outranks any
            // individual note under it.
            if !model.reviews.isEmpty { VerdictList(reviews: model.reviews) }
            if threads.isEmpty, model.reviews.isEmpty {
                ContentUnavailableView("No review comments",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Nobody has commented on this pull request yet."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if threads.isEmpty {
                Spacer(minLength: 0)
            } else if visible.isEmpty {
                ContentUnavailableView("Nothing matches",
                                       systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("No comment matches the current filter or search."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(byFile(visible))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        let unresolved = model.unresolvedThreadCount
        return VStack(spacing: 0) {
            PaneHeader {
                Text("Threads").font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
                Text(verbatim: "\(threads.count) conversation\(threads.count == 1 ? "" : "s")")
                    .font(Typography.meta).foregroundStyle(Palette.textTertiary)
                if unresolved > 0 { Tag("\(unresolved) open", tint: Palette.amber) }
            } trailing: {
            if model.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 28, height: 28)
            } else {
                IconButton("arrow.clockwise", help: "Fetch new commits and reload comments (\u{2318}R)") {
                    Task { await model.refreshPR() }
                }
            }
            }
            HStack(spacing: Spacing.md) {
                SegmentedControl(selection: $filter,
                                 options: Filter.allCases.map { ($0, $0.rawValue) })
                QuietField("Search comments, authors, files", text: $search)
                    .frame(maxWidth: 360)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }

    private func list(_ groups: [(path: String, threads: [CommentThread])]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.path) { group in
                        Section {
                            ForEach(group.threads) { thread in
                                CommentThreadCard(thread: thread) {
                                    open(thread)
                                }
                            }
                        } header: {
                            fileHeader(path: group.path, count: group.threads.count)
                                .id(group.path)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollToTarget(proxy, groups) }
            // Also on change: the sidebar's per-file badge stays clickable
            // while this pane is open, and applying the target only on appear
            // meant every badge after the first did nothing at all.
            .onChange(of: session.commentsScrollTarget) { _, _ in scrollToTarget(proxy, groups) }
        }
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy,
                                _ groups: [(path: String, threads: [CommentThread])]) {
        guard let target = session.commentsScrollTarget else { return }
        session.commentsScrollTarget = nil
        // The section only exists once its file survives the filter.
        guard groups.contains(where: { $0.path == target }) else { return }
        proxy.scrollTo(target, anchor: .top)
    }

    private func fileHeader(path: String, count: Int) -> some View {
        let name = String(path.split(separator: "/").last ?? "")
        let dir = path.split(separator: "/").dropLast().joined(separator: "/")
        return HStack(spacing: 6) {
            Image(systemName: "doc.text").imageScale(.small).foregroundStyle(Palette.textSecondary)
            Text(name).font(Typography.fileName)
            if !dir.isEmpty {
                Text(dir).font(Typography.path).foregroundStyle(Palette.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(verbatim: "\(count)")
                .font(Typography.metaDigits)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Palette.surfaceRaised, in: Capsule())
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(Palette.canvas)
    }

    /// Opens the thread's file in the diff and focuses its line.
    private func open(_ thread: CommentThread) {
        session.selectedLines = thread.line.map { $0...$0 }
        session.selectedFile = thread.path
        session.pane = .diff
    }
}

/// One conversation: where it is anchored, the diff it refers to, and the
/// comments themselves.
struct CommentThreadCard: View {
    @EnvironmentObject var model: AppModel
    let thread: CommentThread
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Button(action: onOpen) {
                    HStack(spacing: Spacing.xs) {
                        if let line = thread.line {
                            Text(verbatim: "Line \(line)").font(Typography.metaDigits)
                        } else {
                            Label("Outdated", systemImage: "clock.arrow.circlepath")
                                .font(Typography.meta)
                        }
                        Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
                    }
                }
                .buttonStyle(QuietButtonStyle())
                // An outdated thread has no line to focus, but its file still
                // opens — that is where the reader wants to land.
                .help(thread.line == nil
                      ? "The diff moved past this comment, so GitHub no longer anchors it to a line. Opens the file."
                      : "Open this file in the diff at line \(thread.line!)")
                Spacer()
            }

            if let hunk = thread.root.diffHunk, !hunk.isEmpty {
                DiffHunkPreview(hunk: hunk)
            }

            ThreadCardView(
                thread: thread,
                onReply: { body in Task { await model.reply(to: thread.root, body: body) } },
                onResolve: { Task { await model.resolve(thread.root) } },
                onEdit: { comment in
                    model.canEdit(comment)
                        ? { body in Task { await model.edit(comment, body: body) } } : nil
                },
                fillsWidth: true)
        }
        .contextMenu {
            Button("Open in Diff", action: onOpen)
            if thread.root.threadID != nil, !thread.resolved {
                Button("Resolve Thread") { Task { await model.resolve(thread.root) } }
            }
            Divider()
            Button("Copy Thread") {
                AppModel.copy(thread.comments.map { "\($0.author): \($0.body)" }.joined(separator: "\n\n"))
            }
        }
    }
}

/// The slice of diff GitHub anchors a comment to, trimmed to its tail — the
/// lines nearest the comment are the ones that give it meaning.
struct DiffHunkPreview: View {
    let hunk: String
    private static let maxLines = 6
    @AppStorage(PrefKey.codeFontFamily) private var codeFontFamily = CodeFont.systemFamily
    @AppStorage(PrefKey.diffFontSize) private var diffFontSize = DiffMetrics.defaultFontSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let lines = hunk.components(separatedBy: "\n").suffix(Self.maxLines)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(Typography.code(family: codeFontFamily,
                                          size: CGFloat(diffFontSize) - 1))
                    .foregroundStyle(color(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(background(for: line))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Palette.hairline) }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("@@") { return Palette.textTertiary }
        if line.hasPrefix("+") { return Palette.addedText }
        if line.hasPrefix("-") { return Palette.removedText }
        return Palette.text
    }

    private func background(for line: String) -> Color {
        let dark = colorScheme == .dark
        if line.hasPrefix("+") { return Palette.diffAddFill(dark) }
        if line.hasPrefix("-") { return Palette.diffRemoveFill(dark) }
        return .clear
    }
}


/// Submitted verdicts, newest last, above the line notes.
private struct VerdictList: View {
    let reviews: [PullRequestReview]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(reviews) { review in
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: icon(review))
                        .foregroundStyle(tint(review))
                        .imageScale(.small)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack(spacing: Spacing.xs) {
                            Text(review.author).font(.callout.weight(.semibold))
                            Text(review.label).font(Typography.meta).foregroundStyle(tint(review))
                            if let at = review.submittedAt {
                                Text(Dates.age(iso: at))
                                    .font(Typography.meta).foregroundStyle(Palette.textTertiary)
                            }
                        }
                        if !review.body.isEmpty { MarkdownBodyView(text: review.body) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint(review).opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.sm))
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    private func icon(_ r: PullRequestReview) -> String {
        r.isApproval ? "checkmark.seal.fill"
            : r.isBlocking ? "xmark.octagon.fill" : "bubble.left"
    }

    private func tint(_ r: PullRequestReview) -> Color {
        r.isApproval ? Palette.addedText : r.isBlocking ? Palette.removedText : Palette.textSecondary
    }
}
