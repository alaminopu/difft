import AppKit
import CryptoKit
import DifftCore
import DifftServices
import DifftUI

/// The places a review can be, as the tab bar names them.
enum ReviewTab: String, CaseIterable, Identifiable {
    case overview, files, threads, findings, commits, walkthrough
    var id: Self { self }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .files: return "Files"
        case .threads: return "Threads"
        case .findings: return "Findings"
        case .commits: return "Commits"
        case .walkthrough: return "Walkthrough"
        }
    }

    /// ⌘1 through ⌘6, in bar order.
    var shortcut: Character { Character("\((Self.allCases.firstIndex(of: self) ?? 0) + 1)") }
}

extension AppModel {
    /// Which tab the current pane belongs to. nil for the pending review,
    /// which is reached from the queue rather than the bar.
    var currentTab: ReviewTab? {
        guard let session else { return nil }
        switch session.pane {
        case .diff: return session.selectedFile == nil ? .overview : .files
        case .comments: return .threads
        case .review: return .findings
        case .commits: return .commits
        case .explain: return .walkthrough
        case .pending: return nil
        }
    }

    /// Switches tab without starting any work.
    ///
    /// The menu's "Explain Diff" and "Review Findings" run the agent when
    /// there is nothing to show yet, which is right for a command named after
    /// the run. A tab is navigation: looking at an empty pane must not spend a
    /// two-minute agent pass.
    func show(_ tab: ReviewTab) {
        guard let session else { return }
        switch tab {
        case .overview:
            showOverview()
        case .files:
            showFiles()
        case .threads:
            closeCommit()
            session.pane = .comments
        case .findings:
            closeCommit()
            session.pane = .review
        case .commits:
            closeCommit()
            session.pane = .commits
        case .walkthrough:
            closeCommit()
            session.pane = .explain
        }
    }

    /// Back to the diff: the file already open, else the one last open, else
    /// the first the reader has not been through.
    func showFiles() {
        guard let session else { return }
        closeCommit()
        session.pane = .diff
        guard session.selectedFile == nil else { return }
        let known = Set(files.map(\.path))
        if let last = lastOpenedFile, known.contains(last) {
            session.selectedFile = last
        } else {
            session.selectedFile = firstUnviewed(after: nil) ?? files.first?.path
        }
    }

    func open(file path: String, line: Int? = nil) {
        guard let session else { return }
        closeCommit()
        session.selectedLines = line.map { $0...$0 }
        session.selectedFile = path
        session.pane = .diff
    }

    /// The next file not yet marked viewed, searching forward from `path` and
    /// wrapping, so marking the last file viewed finds one skipped earlier.
    func firstUnviewed(after path: String?) -> String? {
        guard let session else { return nil }
        let viewed = session.data.viewedFiles
        let start = path.flatMap { p in files.firstIndex { $0.path == p } }.map { $0 + 1 } ?? 0
        let order = Array(files[min(start, files.count)...]) + Array(files[..<min(start, files.count)])
        return order.first { !viewed.contains($0.path) && $0.path != path }?.path
    }

    /// Steps through the files in tree order.
    func stepFile(_ delta: Int) {
        guard let session else { return }
        guard let current = session.selectedFile,
              let index = files.firstIndex(where: { $0.path == current }) else {
            if delta > 0 { session.selectedFile = files.first?.path }
            return
        }
        let next = index + delta
        if files.indices.contains(next) { session.selectedFile = files[next].path }
    }

    /// Marks the open file viewed and moves on. Un-marking stays put: taking
    /// a tick back is a correction, not progress.
    func toggleViewedAndAdvance() {
        guard let session, let path = session.selectedFile else { return }
        let wasViewed = session.data.viewedFiles.contains(path)
        markViewed(path, viewed: !wasViewed)
        let advance = UserDefaults.standard.object(forKey: PrefKey.advanceOnViewed) as? Bool ?? true
        if !wasViewed, advance, let next = firstUnviewed(after: path) { session.selectedFile = next }
    }

    // MARK: - Places outside the app

    /// The PR's disposable checkout.
    var worktreeURL: URL? {
        guard let session else { return nil }
        return Self.appSupportDir
            .appendingPathComponent("worktrees/\(repoName)-pr\(session.data.pr.number)")
    }

    func pullRequestURL(number: Int) -> URL? {
        repoSlug.flatMap { URL(string: "https://github.com/\($0)/pull/\(number)") }
    }

    /// GitHub anchors a file in the Files tab by the SHA-256 of its path.
    func fileURLOnGitHub(_ path: String) -> URL? {
        guard let session, let slug = repoSlug else { return nil }
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://github.com/\(slug)/pull/\(session.data.pr.number)/files#diff-\(digest)")
    }

    func commitURL(_ sha: String) -> URL? {
        repoSlug.flatMap { URL(string: "https://github.com/\($0)/commit/\(sha)") }
    }

    func revealInFinder(_ path: String) {
        guard let url = worktreeURL?.appendingPathComponent(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInEditor(_ path: String) {
        guard let url = worktreeURL?.appendingPathComponent(path) else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
