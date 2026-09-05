import SwiftUI
import DifftCore
import DifftServices

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""

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
                        model.comments = []
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
                PRListView(search: $search)
            }
        }
    }
}

private struct PRListView: View {
    @EnvironmentObject var model: AppModel
    @Binding var search: String

    private var filtered: [PullRequest] {
        guard !search.isEmpty else { return model.prs }
        let q = search.lowercased()
        return model.prs.filter {
            String($0.number).contains(q)
                || $0.title.lowercased().contains(q)
                || $0.authorLogin.lowercased().contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Filter by title, #number or author", text: $search)
                .textFieldStyle(.plain)
                .font(.callout)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)

        HStack {
            Text("Open Pull Requests")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Spacer()
            Text(search.isEmpty ? "\(model.prs.count)" : "\(filtered.count)/\(model.prs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)

        List(filtered) { pr in
            Button {
                Task { await model.openPR(pr) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: "#\(String(pr.number))")
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pr.title).lineLimit(2)
                        Label(pr.authorLogin, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pull request \(pr.number): \(pr.title), by \(pr.authorLogin)")
        }
        .listStyle(.sidebar)
        .overlay {
            if model.prs.isEmpty {
                ContentUnavailableView("No open PRs", systemImage: "tray",
                                       description: Text("Pull requests from `gh pr list` appear here."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .task { await model.loadPRs() }
    }
}

/// One node of the changed-files tree: either a folder (children != nil) or a
/// file leaf. Single-child folder chains are compacted ("src/baserow/api").
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
        let tree = FileTreeNode.build(from: model.files)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    model.session = nil; model.files = []; model.comments = []
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

            Text(verbatim: "#\(String(session.data.pr.number)) \(session.data.pr.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)

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
                session.selectedFile = file.path
            } label: {
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { isViewed },
                        set: { model.markViewed(file.path, viewed: $0) }))
                        .labelsHidden().toggleStyle(.checkbox)
                        .controlSize(.small)
                    Text(node.name)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(isViewed ? .secondary :
                            (session.selectedFile == file.path ? Color.accentColor : .primary))
                    Spacer(minLength: 4)
                    let commentCount = model.comments.count(where: { $0.path == file.path })
                    if commentCount > 0 {
                        Label("\(commentCount)", systemImage: "bubble.left")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
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
