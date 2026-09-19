import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// Preferences for how the changed files are listed.
enum FileListPref {
    static let unviewedOnly = "filesUnviewedOnly"
    static let flat = "filesFlat"
}

/// The changed files, and how far through them the reader is.
///
/// Observes `session` directly (rather than relying on the enclosing view's
/// `AppModel` observation) so it re-renders when `session.data.viewedFiles` or
/// `session.selectedFile` mutate in place.
struct FileTreeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    @State private var filter = ""
    /// Folders the reader opened or closed by hand, by id. Anything absent
    /// follows the default: open while it still has unviewed files.
    @State private var expansion: [String: Bool] = [:]
    @AppStorage(FileListPref.unviewedOnly) private var unviewedOnly = false
    @AppStorage(FileListPref.flat) private var flat = false

    /// One line of the list, already placed.
    private struct Row: Identifiable {
        enum Kind {
            case folder(FileTreeNode, left: Int, expanded: Bool)
            case file(FileDiff, directory: String?)
        }
        let id: String
        let depth: Int
        let kind: Kind
    }

    var body: some View {
        let viewed = session.data.viewedFiles
        let rows = buildRows(viewed: viewed)
        let viewedCount = model.files.count { viewed.contains($0.path) }
        let scale = ChangeBar.scale(for: model.files)
        VStack(spacing: 0) {
            header(viewed: viewedCount)
            controls
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in
                            switch row.kind {
                            case .folder(let node, let left, let expanded):
                                FolderRow(node: node, depth: row.depth, left: left,
                                          expanded: expanded,
                                          toggle: { expansion[node.id] = !expanded },
                                          setViewed: { setViewed(node, $0) })
                            case .file(let file, let directory):
                                FileRow(file: file, directory: directory, depth: row.depth,
                                        isViewed: viewed.contains(file.path),
                                        isSelected: session.pane == .diff
                                            && session.selectedFile == file.path,
                                        threads: model.threadCountsByPath[file.path] ?? 0,
                                        scale: scale, session: session)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.bottom, Spacing.md)
                }
                // J and K move the selection without touching the list, so the
                // list has to follow it.
                .onChange(of: session.selectedFile) { _, path in
                    guard let path else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path) }
                }
            }
            .overlay {
                if rows.isEmpty { emptyState }
            }
            if unviewedOnly, viewedCount > 0 { hiddenFooter(viewedCount) }
        }
    }

    // MARK: - Chrome

    private func header(viewed: Int) -> some View {
        HStack(spacing: Spacing.md) {
            Text("Files").font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
            GeometryReader { geo in
                let fraction = CGFloat(viewed) / CGFloat(max(model.files.count, 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceRaised)
                    Capsule().fill(Palette.added).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 3)
            Text("\(viewed) of \(model.files.count) viewed")
                .font(Typography.metaDigits).foregroundStyle(Palette.textSecondary)
                .fixedSize()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.md)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: Spacing.xs) {
            QuietField("Filter files", text: $filter,
                       systemImage: "line.3.horizontal.decrease")
            Menu {
                Toggle("Unviewed Only", isOn: $unviewedOnly)
                Toggle("Flat List", isOn: $flat)
                Divider()
                Button("Expand All") { setAll(expanded: true) }
                Button("Collapse All") { setAll(expanded: false) }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(unviewedOnly || flat ? Palette.accent : Palette.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("File list options")
            .accessibilityLabel("File list options")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.md)
    }

    private func hiddenFooter(_ count: Int) -> some View {
        HStack {
            Text("Hiding \(count) viewed")
            Spacer()
            Button("Show") { unviewedOnly = false }.buttonStyle(QuietButtonStyle())
        }
        .font(Typography.meta)
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, Spacing.lg)
        .frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.xs) {
            if !filter.isEmpty {
                Text("No file matches").foregroundStyle(Palette.textSecondary)
            } else if unviewedOnly, !model.files.isEmpty {
                Image(systemName: "checkmark.circle").font(.system(size: 22))
                    .foregroundStyle(Palette.added)
                Text("Every file viewed").foregroundStyle(Palette.textSecondary)
            }
        }
        .font(Typography.control)
    }

    // MARK: - Rows

    private func buildRows(viewed: Set<String>) -> [Row] {
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let selected = session.selectedFile

        /// A viewed file stays listed while it is the one on screen, so
        /// ticking it does not pull the row out from under the pointer.
        func shows(_ file: FileDiff) -> Bool {
            if !term.isEmpty, !file.path.lowercased().contains(term) { return false }
            if unviewedOnly, viewed.contains(file.path), file.path != selected { return false }
            return true
        }

        if flat {
            return model.files.filter(shows).map { file in
                let dir = file.path.split(separator: "/").dropLast().joined(separator: "/")
                return Row(id: file.path, depth: 0, kind: .file(file, directory: dir))
            }
        }

        var rows: [Row] = []
        func files(under node: FileTreeNode) -> [FileDiff] {
            if let file = node.file { return [file] }
            return (node.children ?? []).flatMap(files(under:))
        }
        func walk(_ nodes: [FileTreeNode], depth: Int) {
            for node in nodes {
                if let file = node.file {
                    if shows(file) { rows.append(Row(id: file.path, depth: depth, kind: .file(file, directory: nil))) }
                    continue
                }
                let inside = files(under: node)
                guard inside.contains(where: shows) else { continue }
                let left = inside.count { !viewed.contains($0.path) }
                let holdsSelection = inside.contains { $0.path == selected }
                // A search has to show what it found; a folder holding the
                // open file must not fold up around it.
                let expanded = !term.isEmpty
                    || (expansion[node.id] ?? (left > 0 || holdsSelection))
                rows.append(Row(id: "dir:\(node.id)", depth: depth,
                                kind: .folder(node, left: left, expanded: expanded)))
                if expanded { walk(node.children ?? [], depth: depth + 1) }
            }
        }
        walk(model.fileTree, depth: 0)
        return rows
    }

    private func setAll(expanded: Bool) {
        func collect(_ nodes: [FileTreeNode]) {
            for node in nodes where node.children != nil {
                expansion[node.id] = expanded
                collect(node.children ?? [])
            }
        }
        collect(model.fileTree)
    }

    private func setViewed(_ node: FileTreeNode, _ viewed: Bool) {
        func apply(_ node: FileTreeNode) {
            if let file = node.file { model.markViewed(file.path, viewed: viewed) }
            node.children?.forEach(apply)
        }
        apply(node)
    }
}

enum FileTreeMetrics {
    /// Indentation stops growing after a few levels. A monorepo nests eight
    /// deep, and by then the indent had taken the room the file name needed.
    static func indent(_ depth: Int) -> CGFloat { CGFloat(min(depth, 4)) * 10 + CGFloat(max(depth - 4, 0)) * 3 }
}

// MARK: - Folder

private struct FolderRow: View {
    let node: FileTreeNode
    let depth: Int
    let left: Int
    let expanded: Bool
    let toggle: () -> Void
    let setViewed: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 12)
                Text(node.name)
                    .font(Typography.control)
                    .foregroundStyle(left == 0 ? Palette.textTertiary : Palette.textSecondary)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: Spacing.xs)
                Text(left == 0 ? "all viewed" : "\(left) left")
                    .font(Typography.meta)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.leading, FileTreeMetrics.indent(depth) + 6)
            .padding(.trailing, Spacing.sm + 2)
            .frame(height: 28)
            .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // A little air above each top-level group is what stops forty rows
        // reading as one block.
        .padding(.top, depth == 0 ? Spacing.xs : 0)
        .contextMenu {
            Button("Mark All Viewed") { setViewed(true) }.disabled(left == 0)
            Button("Mark All Unviewed") { setViewed(false) }.disabled(left == node.fileCount)
            Divider()
            Button("Copy Path") { AppModel.copy(node.id) }
        }
        .accessibilityLabel("Folder \(node.name), \(left) of \(node.fileCount) files left")
    }
}

// MARK: - File

private struct FileRow: View {
    @EnvironmentObject var model: AppModel
    let file: FileDiff
    /// Shown beside the name in the flat list, where no folder row says it.
    let directory: String?
    let depth: Int
    let isViewed: Bool
    let isSelected: Bool
    let threads: Int
    let scale: Double
    let session: ReviewSession
    @State private var hovering = false

    private var name: String { String(file.path.split(separator: "/").last ?? "") }

    private var nameText: some View {
        Text(name)
            .font(Typography.fileName)
            .foregroundStyle(isSelected ? Palette.textStrong
                             : isViewed ? Palette.textTertiary : Palette.text)
            .lineLimit(1)
    }

    /// Only the exceptions are labelled. "Modified" is nearly every file, and
    /// an M on each of them was a column of noise.
    private var status: (text: String, tint: Color)? {
        switch file.kind {
        case .added: return ("new", Palette.addedText)
        case .deleted: return ("deleted", Palette.removedText)
        case .renamed: return ("renamed", Palette.textSecondary)
        case .binary: return ("binary", Palette.textTertiary)
        case .modified: return nil
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            ViewedRing(isViewed: isViewed) { model.markViewed(file.path, viewed: !isViewed) }
            // The name comes first. Deep in a tree there is not room for it
            // and "new" both, and a file called "00…a.py" identifies nothing.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    nameText.fixedSize()
                    if let status {
                        Text(status.text).font(Typography.meta).foregroundStyle(status.tint)
                            .opacity(isViewed ? 0.6 : 1)
                            .fixedSize()
                    }
                    if let directory, !directory.isEmpty {
                        Text(directory)
                            .font(Typography.meta).foregroundStyle(Palette.textTertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    // Tail, not middle: siblings share an ending far more
                    // often than a beginning ("…Form.vue" for a whole folder),
                    // and "TextEle…orm.vue" kept the half that says nothing.
                    nameText.truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
            if threads > 0 {
                Button {
                    session.commentsScrollTarget = file.path
                    session.pane = .comments
                } label: {
                    Text("\(threads)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(Palette.amber)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 15)
                        .background(Palette.amber.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("\(threads) review thread\(threads == 1 ? "" : "s") — show them")
                .accessibilityLabel("\(threads) review thread\(threads == 1 ? "" : "s") on \(name)")
            }
            ChangeBar(additions: file.additions, deletions: file.deletions,
                      scale: scale, dimmed: isViewed)
        }
        .padding(.leading, FileTreeMetrics.indent(depth) + 10)
        .padding(.trailing, Spacing.sm + 2)
        .frame(height: 28)
        .background(isSelected ? Palette.selection : (hovering ? Palette.hover : .clear),
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { model.open(file: file.path) }
        .onHover { hovering = $0 }
        .id(file.path)
        .help("\(file.path)  +\(file.additions) \u{2212}\(file.deletions)")
        .contextMenu { FileMenu(file: file, isViewed: isViewed) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("File \(file.path), \(file.additions) additions, \(file.deletions) deletions\(isViewed ? ", viewed" : "")")
    }
}

/// Everything a file row can do, also offered from the file header.
struct FileMenu: View {
    @EnvironmentObject var model: AppModel
    let file: FileDiff
    let isViewed: Bool

    var body: some View {
        Button(isViewed ? "Mark as Unviewed" : "Mark as Viewed") {
            model.markViewed(file.path, viewed: !isViewed)
        }
        if (model.threadCountsByPath[file.path] ?? 0) > 0 {
            Button("Show Review Threads") {
                model.session?.commentsScrollTarget = file.path
                model.session?.pane = .comments
            }
        }
        Divider()
        Button("Copy Path") { AppModel.copy(file.path) }
        Button("Copy File Name") {
            AppModel.copy(String(file.path.split(separator: "/").last ?? ""))
        }
        Divider()
        if let url = model.fileURLOnGitHub(file.path) {
            Button("Open on GitHub") { NSWorkspace.shared.open(url) }
        }
        if file.kind != .deleted {
            Button("Open in Default Editor") { model.openInEditor(file.path) }
            Button("Reveal in Finder") { model.revealInFinder(file.path) }
        }
    }
}

/// The viewed tick. A ring rather than a checkbox: forty native checkboxes
/// down a sidebar made it look like a settings form.
struct ViewedRing: View {
    let isViewed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Circle().strokeBorder(isViewed ? Palette.added : Palette.textTertiary.opacity(0.7),
                                      lineWidth: 1.5)
                if isViewed {
                    Circle().fill(Palette.added)
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(Palette.chrome)
                }
            }
            .frame(width: 13, height: 13)
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-4)
        .help(isViewed ? "Viewed — click to unmark" : "Mark as viewed")
        .accessibilityLabel(isViewed ? "Viewed" : "Not viewed")
    }
}

/// How much a file changed, and in which direction, at a glance.
///
/// Replaces "+54 −15" on every row. The exact counts are in the file header
/// and the row's tooltip; what the list needs is where the weight of the pull
/// request sits, and a bar says that without being read.
struct ChangeBar: View {
    let additions: Int
    let deletions: Int
    let scale: Double
    var dimmed = false

    static let width: CGFloat = 28

    /// The largest file's change count, so bars compare across the PR.
    static func scale(for files: [FileDiff]) -> Double {
        Double(max(files.map { $0.additions + $0.deletions }.max() ?? 1, 1))
    }

    var body: some View {
        let total = Double(additions + deletions)
        // Square root, so one four-thousand-line lockfile does not flatten
        // every other bar to a dot.
        let length = total == 0 ? 0 : max(3, Self.width * CGFloat((total / scale).squareRoot()))
        let addWidth = total == 0 ? 0 : (length * CGFloat(Double(additions) / total)).rounded()
        HStack(spacing: 1) {
            if additions > 0 { Rectangle().fill(Palette.added).frame(width: max(addWidth, 1)) }
            if deletions > 0 { Rectangle().fill(Palette.removed).frame(width: max(length - addWidth, 1)) }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, height: 5)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityHidden(true)
    }
}
