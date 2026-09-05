import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// Every commit on the PR, newest first and grouped by the day it was
/// authored — the shape GitHub's own commits tab uses, because a branch's
/// history reads as a sequence of working days.
struct PRCommitsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession

    @State private var search = ""
    @State private var expanded: Set<String> = []

    private var visibleCommits: [Commit] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return model.commits }
        return model.commits.filter {
            $0.subject.lowercased().contains(term)
                || $0.body.lowercased().contains(term)
                || $0.author.lowercased().contains(term)
                || $0.sha.lowercased().hasPrefix(term)
        }
    }

    /// Day label with its commits, preserving the newest-first order the
    /// model already applied.
    private var byDay: [(day: String, commits: [Commit])] {
        var order: [String] = []
        var grouped: [String: [Commit]] = [:]
        for commit in visibleCommits {
            let day = Self.dayLabel(for: commit.date)
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(commit)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.commits.isEmpty {
                ContentUnavailableView("No commits",
                                       systemImage: "arrow.triangle.branch",
                                       description: Text("This pull request has no commits to show."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleCommits.isEmpty {
                ContentUnavailableView("Nothing matches",
                                       systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("No commit matches the current search."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            OverviewBackButton()
            Divider().frame(height: 14)
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text("Commits").font(Typography.sectionTitle)
            Text(verbatim: "\(model.commits.count)")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary).imageScale(.small)
                TextField("Search messages, authors, sha", text: $search)
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
            .frame(maxWidth: 320)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                ForEach(byDay, id: \.day) { group in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(group.commits) { commit in
                                CommitRow(commit: commit,
                                          isExpanded: expanded.contains(commit.sha),
                                          onToggleBody: {
                                    if expanded.contains(commit.sha) {
                                        expanded.remove(commit.sha)
                                    } else {
                                        expanded.insert(commit.sha)
                                    }
                                },
                                          onOpen: { Task { await model.openCommit(commit) } })
                                if commit.sha != group.commits.last?.sha { Divider() }
                            }
                        }
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Palette.cardBorder)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar").imageScale(.small)
                                .foregroundStyle(.secondary)
                            Text(group.day).font(Typography.groupHeader)
                            Text(verbatim: "\(group.commits.count)")
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background(.background.opacity(0.95))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "5 September 2026" for the commit's authored day, or the raw string
    /// when the date will not parse — better a stray header than a crash.
    static func dayLabel(for iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .long
        out.timeStyle = .none
        return out.string(from: date)
    }
}

/// One commit: sha, subject, who and when, and its message body on demand.
struct CommitRow: View {
    let commit: Commit
    var isExpanded: Bool
    var onToggleBody: () -> Void
    /// Opens this commit's own diff.
    var onOpen: () -> Void = {}
    @State private var hovering = false

    private var age: String {
        guard let date = ISO8601DateFormatter().date(from: commit.date) else { return "" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(commit.subject)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if commit.hasBody {
                    Button {
                        onToggleBody()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide the full message" : "Show the full message")
                    .accessibilityLabel(isExpanded ? "Hide commit message body" : "Show commit message body")
                }
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
            HStack(spacing: 6) {
                if !commit.author.isEmpty {
                    Label(commit.author, systemImage: "person")
                }
                Text(age)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if isExpanded, commit.hasBody {
                Text(commit.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .help("Show the diff this commit introduced")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the diff this commit introduced")
    }
}
