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

    @State private var layout: DiffLayout = .sideBySide
    @State private var selection: LineSelection?
    @AppStorage("diffFontSize") private var fontSize = 12

    private var age: String {
        guard let date = ISO8601DateFormatter().date(from: commit.date) else { return "" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoadingCommit {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading \(commit.shortSHA)…").foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.commitFiles.isEmpty {
                // `git show` prints nothing for a merge commit, which is not
                // an error — it just has no diff of its own to show.
                ContentUnavailableView("No changes to show",
                                       systemImage: "arrow.triangle.merge",
                                       description: Text("This commit introduces no diff of its own. Merge commits look like this."))
            } else {
                content
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    model.closeCommit()
                } label: {
                    Label("Commits", systemImage: "chevron.left").font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Back to the commits list")
                .accessibilityLabel("Back to commits")
                Divider().frame(height: 14)
                Text(commit.subject)
                    .font(.callout.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(commit.shortSHA)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.sha, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").imageScale(.small).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy the full sha")
                .accessibilityLabel("Copy commit sha")
            }
            HStack(spacing: 8) {
                if !commit.author.isEmpty { Label(commit.author, systemImage: "person") }
                Text(age)
                if !model.commitFiles.isEmpty {
                    Text(verbatim: "\(model.commitFiles.count) file\(model.commitFiles.count == 1 ? "" : "s")")
                    Text(verbatim: "+\(model.commitFiles.reduce(0) { $0 + $1.additions })")
                        .foregroundStyle(.green).monospacedDigit()
                    Text(verbatim: "−\(model.commitFiles.reduce(0) { $0 + $1.deletions })")
                        .foregroundStyle(.red).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var content: some View {
        HStack(spacing: 0) {
            fileList
            Divider()
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
            }
        }
        .toolbar {
            Picker("Layout", selection: $layout) {
                ForEach(DiffLayout.allCases, id: \.self) { Text($0.rawValue) }
            }.pickerStyle(.segmented)
            Stepper("Font \(fontSize)pt", value: $fontSize, in: 9...18)
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
                                    .lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                                Spacer(minLength: 4)
                                Text(verbatim: "+\(file.additions)")
                                    .foregroundStyle(.green).font(.caption.monospacedDigit())
                                Text(verbatim: "−\(file.deletions)")
                                    .foregroundStyle(.red).font(.caption.monospacedDigit())
                            }
                            if !dir.isEmpty {
                                Text(dir)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("File \(file.path), \(file.additions) additions, \(file.deletions) deletions")
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 240)
        .background(.quaternary.opacity(0.15))
    }
}
