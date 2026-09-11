import SwiftUI
import DifftCore
import DifftServices
import DifftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                    .imageScale(.small)
                Text(model.repoName.isEmpty ? "No repository" : model.repoName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        model.repoDir = url
                        model.session = nil
                        model.files = []
                        model.comments = []; model.commits = []
                        // The old repo's PRs stayed on screen and stayed
                        // clickable while the new list loaded — opening one
                        // ran its number against the wrong checkout.
                        model.prs = []
                        model.prAuthors = []
                        model.currentHead = nil
                        model.refreshNote = nil; model.worktreeNote = nil
                        Task { await model.loadPRs() }
                    }
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Choose repository…")
                .accessibilityLabel("Choose repository")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let session = model.session {
                // NOTE: passed explicitly as @ObservedObject below — a subview observing only
                // AppModel would not re-render when session.data / session.selectedFile mutate,
                // since ReviewSession is a nested ObservableObject (Task 13 controller ruling #2).
                FileTreeView(session: session)
            } else {
                PRListView()
            }
        }
    }
}

/// What the list is currently asking GitHub for. Changing either field
/// restarts the query, so they travel together.
private struct PRQuery: Hashable {
    var scope: PRScope
    var search: String
    var authors: [String]
}

private struct PRListView: View {
    @EnvironmentObject var model: AppModel

    /// How long after the last keystroke the query is sent. Every query is a
    /// `gh` process against GitHub's search API; one per keystroke would both
    /// lag and burn rate limit.
    private static let debounce = Duration.milliseconds(300)
    /// How often the list re-asks while it is on screen. A PR opened in the
    /// browser used to require quitting the app to appear.
    private static let pollInterval = Duration.seconds(60)

    private var query: PRQuery {
        PRQuery(scope: model.prScope, search: model.prSearch,
                authors: model.prAuthors.sorted())
    }

    /// The row a finished query wants at the top. Set only by the query task,
    /// never by the poll, so a background refresh leaves the scroll alone.
    @State private var topOfResults: Int?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            filterRow
            authorChips
            Divider()
            list
        }
        .task(id: query) {
            // The first pass should not wait; only a changing query debounces.
            if !model.prs.isEmpty {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
            }
            await model.loadPRs()
            topOfResults = model.prs.first?.number
        }
        .task {
            // Quietly, so a network blip while the window sits open does not
            // replace the list the user is reading with an error.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                await model.loadPRs(silent: true)
            }
        }
        // Coming back to the app is exactly when a PR opened elsewhere should
        // already be in the list.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.loadPRs(silent: true) }
        }
    }

    private var searchField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Search #number, title, author:login", text: $model.prSearch)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit { Task { await model.loadPRs() } }
            if model.isLoadingPRs {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 14, height: 14)
            } else if !model.prSearch.isEmpty {
                Button { model.prSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Palette.hairline))
        .padding(.horizontal, Spacing.md)
        .help("Searches the whole repository, not just the loaded page. "
              + "A bare number opens that PR whatever its state.")
    }

    private var filterRow: some View {
        HStack(spacing: Spacing.sm) {
            Picker("State", selection: $model.prScope) {
                ForEach(PRScope.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()

            AuthorFilterButton()

            Spacer(minLength: 0)

            Text(model.prsTruncated ? "\(model.prs.count)+" : "\(model.prs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(model.prsTruncated
                      ? "Showing the first \(AppModel.prPageSize); search to narrow it down."
                      : "Pull requests matching the current filter")

            Button { Task { await model.loadPRs() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(model.isLoadingPRs)
            .help("Refresh the list")
            .accessibilityLabel("Refresh pull requests")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    /// The selected authors, shown under the filter row so the narrowing is
    /// visible without opening the picker — and removable in one click.
    @ViewBuilder
    private var authorChips: some View {
        if !model.prAuthors.isEmpty {
            FlowLayout(spacing: Spacing.xs, lineSpacing: Spacing.xs) {
                ForEach(model.prAuthors.sorted(), id: \.self) { login in
                    Button { model.prAuthors.remove(login) } label: {
                        HStack(spacing: Spacing.xs) {
                            Text(login).lineLimit(1)
                            Image(systemName: "xmark").imageScale(.small)
                        }
                        .font(.caption)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Stop filtering by \(login)")
                    .accessibilityLabel("Remove author filter \(login)")
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)
        }
    }

    private var list: some View {
        // A new query is a new list, so it has to start at the top. Without
        // this it kept the offset it held for the previous results, and the
        // row a number search had just pinned to the top rendered with its
        // first line clipped under the filter bar.
        ScrollViewReader { proxy in
            List(model.prs) { pr in
                Button {
                    Task { await model.openPR(pr) }
                } label: {
                    PRRow(pr: pr, opening: model.openingPRNumber == pr.number)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 1, leading: Spacing.xs,
                                          bottom: 1, trailing: Spacing.xs))
                .listRowSeparator(.hidden)
                .accessibilityLabel("Pull request \(pr.number): \(pr.title), by \(pr.authorLogin), \(pr.stateLabel)")
            }
            .onChange(of: topOfResults) { _, top in
                // Only when the query changed: a background refresh must not
                // yank the list out from under someone reading it.
                guard let top else { return }
                proxy.scrollTo(top, anchor: .top)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.prs.isEmpty, !model.isLoadingPRs {
                if model.prSearch.isEmpty {
                    ContentUnavailableView(
                        "No \(model.prScope.label.lowercased()) PRs",
                        systemImage: "tray",
                        description: Text(model.prAuthors.isEmpty
                                          ? "Nothing matches this filter."
                                          : "Nothing from the authors you picked."))
                } else {
                    ContentUnavailableView.search(text: model.prSearch)
                }
            }
        }
    }
}

/// One row of the pull-request list: number, title, who and when, and the
/// state — so a searched-for merged PR is recognisable as merged without
/// opening it.
private struct PRRow: View {
    let pr: PullRequest
    let opening: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(pr.title)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(Typography.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            // A column of its own, top-aligned: inline with the title it slid
            // around as the title wrapped, and landed mid-sentence.
            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                if let badge { StateBadge(text: badge.text, tint: badge.tint) }
                // A first open has to check the PR out into a worktree, which
                // is not quick on a large repo. Without this the click looked
                // like it had not registered.
                if opening { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.sm))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Draft and a closed state are mutually exclusive in practice — GitHub
    /// will not let a merged PR be a draft — so one badge is enough, and one
    /// badge keeps the row a fixed shape.
    private var badge: (text: String, tint: Color)? {
        if !pr.isOpen {
            return (pr.stateLabel, pr.stateLabel == "MERGED" ? .purple : .red)
        }
        if pr.isDraft == true { return ("DRAFT", .secondary) }
        return nil
    }

    private var subtitle: String {
        var parts = ["#\(pr.number)"]
        if let created = Self.created(pr.createdAt) { parts.append(created) }
        if !pr.authorLogin.isEmpty { parts.append(pr.authorLogin) }
        return parts.joined(separator: "  ·  ")
    }

    /// nil rather than a placeholder when the date is missing or unparseable —
    /// the row simply drops that segment.
    static func created(_ iso: String?) -> String? {
        guard let iso, let date = Dates.parse(iso) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

private struct StateBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xs + 1)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}

/// One node of the changed-files tree: either a folder (children != nil) or a
/// file leaf. Single-child folder chains are compacted ("src/app/api").
struct FileTreeNode: Identifiable {
    let id: String        // full path prefix (folders) or file path (leaves)
    let name: String      // display name (possibly compacted "a/b/c")
    var children: [FileTreeNode]?
    var file: FileDiff?
    var fileCount: Int    // leaves under this node (1 for a leaf)

    static func build(from files: [FileDiff]) -> [FileTreeNode] {
        // Insert into a nested dictionary tree, then convert + compact.
        final class Dir {
            var dirs: [String: Dir] = [:]
            var files: [FileDiff] = []
        }
        let root = Dir()
        for f in files {
            var cur = root
            let parts = f.path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                if cur.dirs[part] == nil { cur.dirs[part] = Dir() }
                cur = cur.dirs[part]!
            }
            cur.files.append(f)
        }

        func convert(_ dir: Dir, prefix: String) -> [FileTreeNode] {
            var nodes: [FileTreeNode] = []
            for (name, sub) in dir.dirs.sorted(by: { $0.key < $1.key }) {
                // Compact chains of single-child folders with no files.
                var compactName = name
                var compactPrefix = prefix.isEmpty ? name : "\(prefix)/\(name)"
                var current = sub
                while current.files.isEmpty, current.dirs.count == 1,
                      let (childName, child) = current.dirs.first {
                    compactName += "/\(childName)"
                    compactPrefix += "/\(childName)"
                    current = child
                }
                let children = convert(current, prefix: compactPrefix)
                let count = children.reduce(0) { $0 + $1.fileCount }
                nodes.append(FileTreeNode(id: compactPrefix, name: compactName,
                                          children: children, file: nil, fileCount: count))
            }
            for f in dir.files.sorted(by: { $0.path < $1.path }) {
                let name = String(f.path.split(separator: "/").last ?? "")
                nodes.append(FileTreeNode(id: f.path, name: name,
                                          children: nil, file: f, fileCount: 1))
            }
            return nodes
        }
        return convert(root, prefix: "")
    }
}

/// Renders the file tree for the active session. Observes `session` directly (rather than
/// relying on the enclosing view's `AppModel` observation) so it re-renders when
/// `session.data.viewedFiles` or `session.selectedFile` mutate in place.
struct FileTreeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession

    var body: some View {
        let viewed = session.data.viewedFiles
        let tree = model.fileTree
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    model.session = nil; model.files = []; model.comments = []; model.commits = []
                } label: {
                    Label("PRs", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Spacer()
                Text("\(viewed.count)/\(model.files.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Files viewed")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            let onOverview = session.pane == .diff && session.selectedFile == nil
            Button {
                model.showOverview()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.magnifyingglass").imageScale(.small)
                    Text(verbatim: "#\(String(session.data.pr.number)) \(session.data.pr.title)")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(onOverview ? Color.accentColor : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(onOverview ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .help("Back to the pull request overview (\u{2318}0)")
            .accessibilityLabel("Pull request overview")

            ProgressView(value: Double(viewed.count), total: Double(max(model.files.count, 1)))
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            List {
                ForEach(tree) { node in
                    FileTreeNodeView(node: node, session: session)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct FileTreeNodeView: View {
    let node: FileTreeNode
    @ObservedObject var session: ReviewSession
    @EnvironmentObject var model: AppModel
    @State private var expanded = true

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(children) { child in
                    FileTreeNodeView(node: child, session: session)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                    Text(node.name).lineLimit(1).truncationMode(.head)
                    Text("\(node.fileCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        } else if let file = node.file {
            let isViewed = session.data.viewedFiles.contains(file.path)
            Button {
                session.pane = .diff
                model.closeCommit()
                session.selectedFile = file.path
            } label: {
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { isViewed },
                        set: { model.markViewed(file.path, viewed: $0) }))
                        .labelsHidden().toggleStyle(.checkbox)
                        .controlSize(.small)
                    Text(node.name)
                        .font(Typography.fileName)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(isViewed ? .secondary :
                            (session.selectedFile == file.path ? Color.accentColor : .primary))
                    Spacer(minLength: 4)
                    let commentCount = model.threadCountsByPath[file.path] ?? 0
                    if commentCount > 0 {
                        Button {
                            session.commentsScrollTarget = file.path
                            session.pane = .comments
                        } label: {
                            Label("\(commentCount)", systemImage: "bubble.left")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .help("Show this file's review comments")
                        .accessibilityLabel("\(commentCount) review thread\(commentCount == 1 ? "" : "s") on \(node.name)")
                    }
                    Text("+\(file.additions)")
                        .foregroundStyle(.green).font(.caption.monospacedDigit())
                    Text("−\(file.deletions)")
                        .foregroundStyle(.red).font(.caption.monospacedDigit())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("File \(file.path), \(file.additions) additions, \(file.deletions) deletions")
        }
    }
}
