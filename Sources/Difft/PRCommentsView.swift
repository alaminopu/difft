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

    private var threads: [CommentThread] { CommentThread.group(model.comments) }

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
    private var byFile: [(path: String, threads: [CommentThread])] {
        var order: [String] = []
        var grouped: [String: [CommentThread]] = [:]
        for thread in visibleThreads {
            if grouped[thread.path] == nil { order.append(thread.path) }
            grouped[thread.path, default: []].append(thread)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if threads.isEmpty {
                ContentUnavailableView("No review comments",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Nobody has commented on this pull request yet."))
            } else if visibleThreads.isEmpty {
                ContentUnavailableView("Nothing matches",
                                       systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("No comment matches the current filter or search."))
            } else {
                list
            }
        }
    }

    private var header: some View {
        let unresolved = threads.count { !$0.resolved }
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
                Text("Review comments").font(.headline)
                Text(verbatim: "\(threads.count) thread\(threads.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)
                if unresolved > 0 {
                    Text(verbatim: "\(unresolved) unresolved")
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }
                Spacer()
                Button {
                    Task { await model.refreshPR() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshing)
                .help("Fetch new commits and reload comments (⌘R)")
                .accessibilityLabel("Refresh pull request")
                Button {
                    session.showComments = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back to PR overview")
                .accessibilityLabel("Close comments")
            }
            HStack(spacing: 10) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary).imageScale(.small)
                    TextField("Search comments, authors, files", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    ForEach(byFile, id: \.path) { group in
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
            .onAppear {
                guard let target = session.commentsScrollTarget else { return }
                session.commentsScrollTarget = nil
                // The section only exists once its file survives the filter.
                guard byFile.contains(where: { $0.path == target }) else { return }
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    private func fileHeader(path: String, count: Int) -> some View {
        let name = String(path.split(separator: "/").last ?? "")
        let dir = path.split(separator: "/").dropLast().joined(separator: "/")
        return HStack(spacing: 6) {
            Image(systemName: "doc.text").imageScale(.small).foregroundStyle(.secondary)
            Text(name).font(.callout.monospaced().bold())
            if !dir.isEmpty {
                Text(dir).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(verbatim: "\(count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(.background.opacity(0.95))
    }

    /// Opens the thread's file in the diff and focuses its line.
    private func open(_ thread: CommentThread) {
        session.selectedLines = thread.line.map { $0...$0 }
        session.selectedFile = thread.path
        session.showComments = false
    }
}

/// One conversation: where it is anchored, the diff it refers to, and the
/// comments themselves.
struct CommentThreadCard: View {
    let thread: CommentThread
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let line = thread.line {
                    Text(verbatim: "Line \(line)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else {
                    Label("Outdated", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("The diff moved past this comment, so GitHub no longer anchors it to a line")
                }
                if thread.resolved {
                    Label("Resolved", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                if thread.replies.count > 0 {
                    Text(verbatim: "\(thread.replies.count) repl\(thread.replies.count == 1 ? "y" : "ies")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onOpen()
                } label: {
                    Label("Open in diff", systemImage: "arrow.right.circle")
                        .font(.caption)
                }
                .buttonStyle(.link)
                // An outdated thread has no line to focus, but its file still
                // opens — that is where the reader wants to land.
                .help(thread.line == nil
                      ? "Open this file in the diff (the comment has no current line)"
                      : "Open this file in the diff at line \(thread.line!)")
            }

            if let hunk = thread.root.diffHunk, !hunk.isEmpty {
                DiffHunkPreview(hunk: hunk)
            }

            ForEach(thread.comments) { comment in
                CommentCardView(comment: comment, indented: false)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08))
        }
    }
}

/// The slice of diff GitHub anchors a comment to, trimmed to its tail — the
/// lines nearest the comment are the ones that give it meaning.
struct DiffHunkPreview: View {
    let hunk: String
    private static let maxLines = 6

    var body: some View {
        let lines = hunk.components(separatedBy: "\n").suffix(Self.maxLines)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(background(for: line))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("@@") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary.opacity(0.8)
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") { return .green.opacity(0.12) }
        if line.hasPrefix("-") { return .red.opacity(0.12) }
        return .clear
    }
}
