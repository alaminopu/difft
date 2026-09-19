import SwiftUI
import UniformTypeIdentifiers
import DifftServices
import DifftUI

// MARK: - Home

/// What the window shows with no repository open: the way to open one, and
/// the ones opened before.
///
/// There was no such page. A first launch showed an empty pull-request list
/// beside the words "Pick a PR", and the only way to choose a checkout was a
/// small folder icon.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Difft").font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Palette.textStrong)
                Text("Review pull requests with the whole file in front of you.")
                    .font(.system(size: 15)).foregroundStyle(Palette.textSecondary)
            }
            HStack(spacing: Spacing.md) {
                Button("Open a repository\u{2026}") { model.chooseRepository() }
                    .buttonStyle(PrimaryButtonStyle())
                Text("or drop a folder here").font(Typography.control)
                    .foregroundStyle(Palette.textTertiary)
            }
            if !model.recentRepos.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("RECENT").font(Typography.eyebrow).kerning(0.6)
                        .foregroundStyle(Palette.textTertiary)
                    VStack(spacing: 0) {
                        ForEach(Array(model.recentRepos.enumerated()), id: \.element) { index, url in
                            if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                            RecentRow(url: url)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                    .card()
                }
            }
            Text("Difft needs a local clone: it checks each pull request out into a disposable "
                 + "worktree beside your own, so the diff can show every file end to end.")
                .font(Typography.control).foregroundStyle(Palette.textTertiary)
                .lineSpacing(Typography.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(Spacing.xl * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(Spacing.lg)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await model.openRepository(at: url) }
            }
            return true
        }
    }
}

private struct RecentRow: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @State private var hovering = false

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var body: some View {
        Button { Task { await model.openRepository(at: url) } } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "folder").font(.system(size: 14))
                    .foregroundStyle(Palette.textTertiary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(exists ? Palette.textStrong : Palette.textTertiary)
                    Text(exists ? Self.tilde(url.deletingLastPathComponent().path) : "No longer there")
                        .font(Typography.meta).foregroundStyle(Palette.textTertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary).opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Spacing.lg)
            .frame(height: 50)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { Task { await model.openRepository(at: url) } }.disabled(!exists)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .disabled(!exists)
            Button("Copy Path") { AppModel.copy(url.path) }
            Divider()
            Button("Remove from Recent") { model.removeRecent(url) }
        }
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Pull requests

/// What the list is currently asking GitHub for. Changing any field restarts
/// the query, so they travel together.
private struct PRQuery: Hashable {
    var scope: PRScope
    var search: String
    var authors: [String]
}

/// The repository's pull requests, as the page you choose one from.
///
/// This was a 280pt sidebar list next to an empty pane. Choosing what to
/// review is the whole task at that moment, so it gets the window: titles are
/// no longer cut to two narrow lines, and each row has room to say whose it
/// is, which branch, and whether you have already started on it.
struct PullRequestsView: View {
    @EnvironmentObject var model: AppModel

    /// How long after the last keystroke the query is sent. Every query is a
    /// `gh` process against GitHub's search API; one per keystroke would both
    /// lag and burn rate limit.
    private static let debounce = Duration.milliseconds(300)
    /// How often the list re-asks while it is on screen. A PR opened in the
    /// browser used to require quitting the app to appear.
    private static let pollInterval = Duration.seconds(60)

    private var query: PRQuery {
        PRQuery(scope: model.prScope, search: model.prSearch, authors: model.prAuthors.sorted())
    }

    /// Set only by the query task, never by the poll, so a background refresh
    /// leaves the scroll alone.
    @State private var topOfResults: Int?
    private static let topAnchor = "pull-requests-top"

    var body: some View {
        VStack(spacing: 0) {
            controls
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        // Scrolling to the first row would skip the padding
                        // above it and park the list against the header.
                        Color.clear.frame(height: 0).id(Self.topAnchor)
                        authorChips
                        if model.prs.isEmpty {
                            emptyState
                        } else {
                            list
                            if model.prsTruncated {
                                Text("Showing the first \(AppModel.prPageSize). Search to narrow it down.")
                                    .font(Typography.meta).foregroundStyle(Palette.textTertiary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(maxWidth: 940, alignment: .leading)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                // A new query is a new list, so it starts at the top.
                .onChange(of: topOfResults) { _, top in
                    guard top != nil else { return }
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
            }
        }
        .background(Palette.canvas)
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

    private var controls: some View {
        PaneHeader {
            Text("Pull requests").font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
            Text(model.prsTruncated ? "\(model.prs.count)+" : "\(model.prs.count)")
                .font(Typography.metaDigits).foregroundStyle(Palette.textTertiary)
            QuietField("Search title, #number, author:login", text: $model.prSearch)
                .frame(maxWidth: 340)
                .onSubmit { Task { await model.loadPRs() } }
                .help("Searches the whole repository, not just the loaded page. "
                      + "A bare number opens that PR whatever its state.")
        } trailing: {
            // Open scopes side by side, because they are what you switch
            // between; the closed ones live behind the menu beside them.
            SegmentedControl(selection: $model.prScope,
                             options: PRScope.openScopes.map { ($0, $0.shortLabel) })
                .help("All open includes drafts, the way GitHub's own Open tab does.")
            Menu {
                Picker("State", selection: $model.prScope) {
                    ForEach(PRScope.closedScopes) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(PRScope.closedScopes.contains(model.prScope) ? model.prScope.label : "Closed")
                    .font(Typography.control)
                    .foregroundStyle(PRScope.closedScopes.contains(model.prScope)
                                     ? Palette.accent : Palette.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            AuthorFilterButton()
            if model.isLoadingPRs {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 28, height: 28)
            } else {
                IconButton("arrow.clockwise", help: "Refresh the list") {
                    Task { await model.loadPRs() }
                }
            }
        }
    }

    /// The selected authors, shown above the list so the narrowing is visible
    /// without opening the picker — and removable in one click.
    @ViewBuilder private var authorChips: some View {
        if !model.prAuthors.isEmpty {
            FlowLayout(spacing: Spacing.xs, lineSpacing: Spacing.xs) {
                ForEach(model.prAuthors.sorted(), id: \.self) { login in
                    Button { model.prAuthors.remove(login) } label: {
                        HStack(spacing: Spacing.xs) {
                            Text(login).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                        }
                        .font(Typography.meta)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 3)
                        .background(Palette.activeChip, in: Capsule())
                        .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Stop filtering by \(login)")
                    .accessibilityLabel("Remove author filter \(login)")
                }
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(model.prs.enumerated()), id: \.element.id) { index, pr in
                if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                PRRow(pr: pr, opening: model.openingPRNumber == pr.number,
                      progress: model.reviewProgress[pr.number])
                    .id(pr.number)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .card()
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            if model.isLoadingPRs {
                ProgressView().controlSize(.small)
                Text("Asking GitHub\u{2026}").foregroundStyle(Palette.textTertiary)
            } else {
                Image(systemName: model.prSearch.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(Palette.textTertiary)
                Text(model.prSearch.isEmpty ? "Nothing here" : "No results for \u{201C}\(model.prSearch)\u{201D}")
                    .font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
                Text(!model.prSearch.isEmpty ? "Check the spelling, or try a PR number."
                     : model.prAuthors.isEmpty ? model.prScope.emptyDescription
                     : "Nothing from the authors you picked.")
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .font(Typography.control)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl * 3)
    }
}

private extension PRScope {
    /// For the segmented control, where "Ready for review" does not fit.
    var shortLabel: String {
        switch self {
        case .open: return "All open"
        case .ready: return "Ready"
        case .draft: return "Drafts"
        default: return label
        }
    }
}

/// One pull request: what it is, whose, and how far through it you are.
private struct PRRow: View {
    @EnvironmentObject var model: AppModel
    let pr: PullRequest
    let opening: Bool
    let progress: ReviewProgress?
    @State private var hovering = false

    private var state: (icon: String, tint: Color, label: String?) {
        if !pr.isOpen {
            return pr.stateLabel == "MERGED"
                ? ("arrow.triangle.merge", .purple, "Merged")
                : ("xmark.circle", Palette.removedText, "Closed")
        }
        return pr.isDraft == true
            ? ("circle.dashed", Palette.textTertiary, "Draft")
            : ("arrow.triangle.pull", Palette.addedText, nil)
    }

    var body: some View {
        Button { Task { await model.openPR(pr) } } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: state.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state.tint)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(pr.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.textStrong)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Spacing.sm) {
                        Text(verbatim: "#\(pr.number)").monospacedDigit()
                        if !pr.authorLogin.isEmpty {
                            AvatarDisc(login: pr.authorLogin, size: 15)
                            Text(pr.authorLogin).foregroundStyle(Palette.textSecondary)
                        }
                        if let created = Self.created(pr.createdAt) { Text(created) }
                        Text(pr.headRefName).font(Typography.identifier)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .font(Typography.meta)
                    .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: Spacing.md)
                HStack(spacing: Spacing.sm) {
                    if let progress { Tag(Self.describe(progress), tint: Palette.accent) }
                    if let label = state.label { Tag(label, tint: state.tint) }
                    // A first open has to check the PR out into a worktree,
                    // which is not quick on a large repo. Without this the
                    // click looked like it had not registered.
                    if opening { ProgressView().controlSize(.small).scaleEffect(0.8) }
                }
                .padding(.top, 1)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { PRRowMenu(pr: pr) }
        .accessibilityLabel("Pull request \(pr.number): \(pr.title), by \(pr.authorLogin), \(pr.stateLabel)")
    }

    static func describe(_ p: ReviewProgress) -> String {
        if p.drafts > 0 { return "\(p.drafts) note\(p.drafts == 1 ? "" : "s") staged" }
        if p.viewed > 0 { return "\(p.viewed) file\(p.viewed == 1 ? "" : "s") viewed" }
        return "Reviewed by Claude"
    }

    /// nil rather than a placeholder when the date is missing or unparseable —
    /// the row simply drops that segment.
    static func created(_ iso: String?) -> String? {
        guard let iso, let date = Dates.parse(iso) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// Right-click on a pull request: the things you would otherwise open it, or
/// a browser, to do.
struct PRRowMenu: View {
    @EnvironmentObject var model: AppModel
    let pr: PullRequest

    var body: some View {
        Button("Open") { Task { await model.openPR(pr) } }
        if let url = model.pullRequestURL(number: pr.number) {
            Button("Open on GitHub") { NSWorkspace.shared.open(url) }
            Divider()
            Button("Copy Link") { AppModel.copy(url.absoluteString) }
        } else {
            Divider()
        }
        Button("Copy Number") { AppModel.copy("#\(pr.number)") }
        Button("Copy Branch Name") { AppModel.copy(pr.headRefName) }
        Button("Copy Title") { AppModel.copy(pr.title) }
        if !pr.authorLogin.isEmpty {
            Divider()
            Button("Show Only \(pr.authorLogin)\u{2019}s Pull Requests") {
                model.rememberAuthor(pr.authorLogin)
                model.prAuthors = [pr.authorLogin]
            }
        }
    }
}
