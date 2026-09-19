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
        PaneHeader {
            Text("Commits").font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
            Text(verbatim: "\(model.commits.count)")
                .font(Typography.metaDigits).foregroundStyle(Palette.textTertiary)
            QuietField("Search messages, authors, sha", text: $search)
                .frame(maxWidth: 320)
        } trailing: {
            if model.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 28, height: 28)
            } else {
                IconButton("arrow.clockwise", help: "Fetch new commits and reload comments (\u{2318}R)") {
                    Task { await model.refreshPR() }
                }
            }
        }
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
                        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                        .card()
                    } header: {
                        HStack(spacing: 6) {
                            Text(group.day).font(Typography.groupHeader)
                                .foregroundStyle(Palette.textStrong)
                            Text(verbatim: "\(group.commits.count)")
                                .font(Typography.metaDigits).foregroundStyle(Palette.textTertiary)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background(Palette.canvas)
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
    static func dayLabel(for iso: String) -> String { Dates.day(iso: iso) }
}

/// One commit: sha, subject, who and when, and its message body on demand.
struct CommitRow: View {
    let commit: Commit
    var isExpanded: Bool
    var onToggleBody: () -> Void
    /// Opens this commit's own diff.
    var onOpen: () -> Void = {}
    @State private var hovering = false

    private var age: String { Dates.age(iso: commit.date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(commit.subject)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if commit.hasBody {
                    Button {
                        onToggleBody()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .imageScale(.small)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide the full message" : "Show the full message")
                    .accessibilityLabel(isExpanded ? "Hide commit message body" : "Show commit message body")
                }
                Text(commit.shortSHA)
                    .font(Typography.identifier)
                    .foregroundStyle(Palette.textSecondary)
            }
            HStack(spacing: 6) {
                if !commit.author.isEmpty {
                    AvatarDisc(login: commit.author, size: 16)
                    Text(commit.author)
                }
                Text(age).foregroundStyle(Palette.textTertiary)
            }
            .font(Typography.meta)
            .foregroundStyle(Palette.textSecondary)

            if isExpanded, commit.hasBody {
                Text(commit.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(Typography.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Palette.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .help("Show the diff this commit introduced")
        .contextMenu { CommitMenu(commit: commit, onOpen: onOpen) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the diff this commit introduced")
    }
}

/// Right-click on a commit, here and in its diff header.
struct CommitMenu: View {
    @EnvironmentObject var model: AppModel
    let commit: Commit
    var onOpen: (() -> Void)?

    var body: some View {
        if let onOpen { Button("Show Changes", action: onOpen) }
        if let url = model.commitURL(commit.sha) {
            Button("Open on GitHub") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Copy SHA") { AppModel.copy(commit.sha) }
        Button("Copy Short SHA") { AppModel.copy(commit.shortSHA) }
        Button("Copy Message") {
            AppModel.copy(commit.hasBody ? "\(commit.subject)\n\n\(commit.body)" : commit.subject)
        }
    }
}
