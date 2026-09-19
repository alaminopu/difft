import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// The diff a single commit introduced, drilled into from the commits list.
///
/// This keeps its own file list rather than reusing the sidebar's, because the
/// sidebar is scoped to the whole PR: mixing the two would leave you unsure
/// which set of changes you are looking at.
struct CommitDiffView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    let commit: Commit
    var onAsk: (String, String) -> Void

    @AppStorage(PrefKey.diffLayout) private var layout: DiffLayout = .sideBySide
    @State private var selection: LineSelection?
    @AppStorage(PrefKey.diffFontSize) private var fontSize = DiffMetrics.defaultFontSize

    private var age: String { Dates.age(iso: commit.date) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isLoadingCommit {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading \(commit.shortSHA)…").foregroundStyle(Palette.textSecondary).font(Typography.body)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.commitFiles.isEmpty {
                // `git show` prints nothing for a merge commit, which is not
                // an error — it just has no diff of its own to show.
                ContentUnavailableView("No changes to show",
                                       systemImage: "arrow.triangle.merge",
                                       description: Text("This commit introduces no diff of its own. Merge commits look like this."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        PaneHeader {
            Button { model.closeCommit() } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Commits")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .help("Back to the commits list")
            .accessibilityLabel("Back to commits")
            Text(commit.subject)
                .font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
                .lineLimit(1).truncationMode(.tail)
            Text(commit.shortSHA).font(Typography.identifier)
                .foregroundStyle(Palette.textSecondary)
            if !commit.author.isEmpty {
                Text("\(commit.author) \u{00B7} \(age)").font(Typography.meta)
                    .foregroundStyle(Palette.textTertiary).lineLimit(1)
            }
        } trailing: {
            if !model.commitFiles.isEmpty {
                HStack(spacing: 6) {
                    Text(verbatim: "+\(model.commitFiles.reduce(0) { $0 + $1.additions })")
                        .foregroundStyle(Palette.addedText)
                    Text(verbatim: "\u{2212}\(model.commitFiles.reduce(0) { $0 + $1.deletions })")
                        .foregroundStyle(Palette.removedText)
                }
                .font(.system(size: 12, design: .monospaced))
                SegmentedControl(selection: $layout,
                                 options: [(.sideBySide, "Split"), (.unified, "Unified")])
            }
        }
        .contextMenu { CommitMenu(commit: commit) }
    }

    private var content: some View {
        HStack(spacing: 0) {
            fileList
            Rectangle().fill(Palette.hairline).frame(width: 1)
            if let path = session.selectedCommitFile,
               let file = model.commitFiles.first(where: { $0.path == path }) {
                FileDiffView(file: file, layout: $layout, selection: $selection,
                             fontSize: fontSize,
                             // PR review comments anchor to lines in the PR
                             // head, not to this commit's numbering, so they
                             // are deliberately not shown here.
                             comments: [],
                             onAsk: onAsk)
                    .id(file.path)
                    .onChange(of: file.path) { selection = nil }
            } else {
                ContentUnavailableView("Pick a file", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.commitFiles, id: \.path) { file in
                    let name = String(file.path.split(separator: "/").last ?? "")
                    let dir = file.path.split(separator: "/").dropLast().joined(separator: "/")
                    let isSelected = session.selectedCommitFile == file.path
                    Button {
                        session.selectedCommitFile = file.path
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(name)
                                    .font(Typography.fileName)
                                    .lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(isSelected ? Palette.textStrong : Palette.text)
                                Spacer(minLength: 4)
                                ChangeBar(additions: file.additions, deletions: file.deletions,
                                          scale: ChangeBar.scale(for: model.commitFiles))
                            }
                            if !dir.isEmpty {
                                Text(dir)
                                    .font(Typography.path)
                                    .foregroundStyle(Palette.textTertiary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                        .padding(.horizontal, Spacing.sm + 2).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Palette.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("File \(file.path), \(file.additions) additions, \(file.deletions) deletions")
                }
            }
            .padding(Spacing.sm)
        }
        .frame(width: 260)
        .background(Palette.chrome)
    }
}
