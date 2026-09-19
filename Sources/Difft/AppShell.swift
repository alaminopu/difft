import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// Preference keys owned by the shell.
enum ShellPref {
    static let showSidebar = "showSidebar"
    static let sidebarWidth = "sidebarWidth"
    /// A new key rather than the old `showRightPanel`: that one defaulted to
    /// hidden because the panel was an assistant you summoned. The queue is
    /// part of the review, so it starts open.
    static let showPanel = "showQueuePanel"
    static let panelWidth = "queuePanelWidth"
    static let panelTab = "queuePanelTab"
}

/// Which face of the side panel is showing.
enum PanelTab: Int { case queue = 0, ask = 1 }

/// The window: a tab bar across the top, files on the left, the pane in the
/// middle, the review queue on the right.
///
/// Laid out by hand rather than with `NavigationSplitView`. The split view
/// owns its sidebar's material and its toolbar, and the design needs neither:
/// the bar spans the whole window, and every surface is an opaque colour the
/// app chose.
struct MainSplitView: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingAsk: (text: String, chip: String)?
    @State private var showJump = false
    @AppStorage(ShellPref.showSidebar) private var showSidebar = true
    @AppStorage(ShellPref.sidebarWidth) private var sidebarWidth = 272.0
    @AppStorage(ShellPref.showPanel) private var showPanel = true
    @AppStorage(ShellPref.panelWidth) private var panelWidth = 300.0
    @AppStorage(ShellPref.panelTab) private var panelTab = PanelTab.queue.rawValue

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showJump: $showJump, showSidebar: $showSidebar, showPanel: $showPanel)
            HStack(spacing: 0) {
                // Files belong to a pull request; the pages before one is open
                // have the window to themselves.
                if showSidebar, model.session != nil {
                    SidebarView()
                        .frame(width: sidebarWidth)
                        .background(Palette.chrome)
                    ResizeHandle(width: $sidebarWidth, range: 220...460, growsTrailing: true)
                }
                VStack(spacing: 0) {
                    if let banner = model.errorBanner { ErrorBanner(text: banner) }
                    CenterView { text, chip in
                        pendingAsk = (text, chip)
                        panelTab = PanelTab.ask.rawValue
                        showPanel = true
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    StatusBar()
                }
                .frame(minWidth: 480, maxWidth: .infinity)
                .background(Palette.canvas)
                // Without a session the panel has nothing to queue.
                if showPanel, model.session != nil {
                    ResizeHandle(width: $panelWidth, range: 260...460, growsTrailing: false)
                    RightPanel(pendingAsk: $pendingAsk, tab: $panelTab)
                        .frame(width: panelWidth)
                        .background(Palette.chrome)
                }
            }
        }
        .background(Palette.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator())
        .overlay {
            if showJump, model.session != nil {
                JumpPalette(isPresented: $showJump)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .difftJump)) { _ in
            if model.session != nil { showJump = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .difftToggleSidebar)) { _ in
            showSidebar.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .difftTogglePanel)) { _ in
            showPanel.toggle()
        }
    }
}

extension Notification.Name {
    static let difftJump = Notification.Name("difftJump")
    static let difftToggleSidebar = Notification.Name("difftToggleSidebar")
    static let difftTogglePanel = Notification.Name("difftTogglePanel")
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @Binding var showJump: Bool
    @Binding var showSidebar: Bool
    @Binding var showPanel: Bool

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: Chrome.trafficLights)
            if let session = model.session {
                IconButton("sidebar.left", help: "Show or hide the file list (\u{2303}\u{2318}S)") {
                    showSidebar.toggle()
                }
                .padding(.trailing, Spacing.sm)
                // Observed directly: the counts on the tabs come from the
                // session, which does not republish through AppModel.
                SessionTabs(session: session)
                Spacer(minLength: Spacing.md)
                JumpField { showJump = true }
                IconButton("sidebar.right", help: "Show or hide the review queue (\u{2325}\u{2318}0)",
                           active: showPanel) {
                    showPanel.toggle()
                }
                .padding(.leading, Spacing.xs)
            } else {
                RepositoryButton()
                Spacer()
            }
        }
        .padding(.trailing, Spacing.md)
        .frame(height: Chrome.topBar)
        .background(Palette.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

/// With no PR open the bar says which checkout the list is for, and switches
/// to another.
private struct RepositoryButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            let others = model.recentRepos.filter {
                $0.standardizedFileURL != model.repoDir?.standardizedFileURL
            }
            if !others.isEmpty {
                Section("Recent") {
                    ForEach(others, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            Task { await model.openRepository(at: url) }
                        }
                    }
                }
            }
            Button("Open Repository\u{2026}") { model.chooseRepository() }
            if let dir = model.repoDir {
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                Button("Close Repository") { model.closeRepository() }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder").font(.system(size: 12.5))
                    .foregroundStyle(Palette.textTertiary)
                Text(model.repoName.isEmpty ? "No repository" : model.repoName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textStrong)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, Spacing.sm)
        .help("Switch repository (\u{2318}O opens another)")
    }
}

private struct SessionTabs: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession

    var body: some View {
        HStack(spacing: 2) {
            Button { model.closePullRequest() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .semibold))
                    Text(model.repoName).foregroundStyle(Palette.textSecondary)
                    Text("/").foregroundStyle(Palette.textTertiary)
                    Text(verbatim: "#\(session.data.pr.number)")
                        .fontWeight(.semibold).foregroundStyle(Palette.textStrong)
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .padding(.trailing, Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the pull request list")
            .accessibilityLabel("Back to pull requests")

            ForEach(ReviewTab.allCases) { tab in
                TabButton(tab: tab, active: model.currentTab == tab,
                          count: count(for: tab)) { model.show(tab) }
            }
        }
    }

    private func count(for tab: ReviewTab) -> (text: String, tint: Color)? {
        switch tab {
        case .overview, .walkthrough:
            return nil
        case .files:
            guard !model.files.isEmpty else { return nil }
            let viewed = model.files.count { session.data.viewedFiles.contains($0.path) }
            return ("\(viewed) / \(model.files.count)", Palette.textTertiary)
        case .threads:
            // Still loading is not the same as none.
            guard !model.isLoadingDetails, !model.threads.isEmpty else { return nil }
            let open = model.unresolvedThreadCount
            return open > 0 ? ("\(open)", Palette.amber) : ("\(model.threads.count)", Palette.textTertiary)
        case .findings:
            let open = session.data.findings.filter { !$0.dismissed }
            guard !open.isEmpty else { return nil }
            let tint = open.contains { $0.severityRank == 0 } ? Palette.removedText : Palette.amber
            return ("\(open.count)", tint)
        case .commits:
            guard !model.isLoadingDetails, !model.commits.isEmpty else { return nil }
            return ("\(model.commits.count)", Palette.textTertiary)
        }
    }
}

private struct TabButton: View {
    let tab: ReviewTab
    let active: Bool
    let count: (text: String, tint: Color)?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(tab.label)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active || hovering ? Palette.textStrong : Palette.textSecondary)
                if let count {
                    Text(count.text)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(count.tint)
                }
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: Chrome.topBar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(active ? Palette.accent : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(tab.label) (\u{2318}\(String(tab.shortcut)))")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Looks like a field, opens the palette — the typing happens there, over the
/// window, where the results have room.
private struct JumpField: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5))
                Text("Jump to file or line").font(Typography.control)
                Spacer(minLength: 0)
                KeyCap("\u{2318}K")
            }
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 10)
            .frame(width: 250, height: 28)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.cardBorder) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to a file, a line, or a tab (\u{2318}K)")
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showShortcuts = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            if let s = model.session {
                Text(s.data.pr.title)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Text(verbatim: "\(s.data.pr.headRefName) \u{2192} \(s.data.pr.baseRefName ?? "base")")
                    .font(Typography.identifier)
                    .lineLimit(1)
                // AgentStatusView observes ReviewSession directly, so it is
                // handed a concrete session rather than reading model.session.
                AgentStatusView(session: s)
            }
            Spacer(minLength: 0)
            if let note = model.worktreeNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.amber).lineLimit(1).help(note)
            } else if let note = model.refreshNote {
                Text(note).transition(.opacity)
            }
            Button { showShortcuts.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Keyboard shortcuts")
                    KeyCap("?")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showShortcuts, arrowEdge: .top) { ShortcutSheet() }
        }
        .font(Typography.meta)
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, Spacing.lg)
        .frame(height: Chrome.statusBar)
        .background(Palette.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

/// Every shortcut in one place. They used to be hinted on the controls
/// themselves, which put a key cap on half the buttons in the window.
struct ShortcutSheet: View {
    static let groups: [(title: String, rows: [(keys: String, what: String)])] = [
        ("Move", [
            ("J  K", "Next and previous file"),
            ("N  P", "Next and previous change in the file"),
            ("\u{2318}K", "Jump to a file, line or tab"),
            ("\u{2318}1 \u{2013} \u{2318}6", "Overview, Files, Threads, Findings, Commits, Walkthrough"),
        ]),
        ("Review", [
            ("V", "Mark the file viewed and move on"),
            ("C", "Comment on the selected lines"),
            ("A", "Ask Claude about the selected lines"),
            ("\u{21E7}\u{2318}Y", "Your review"),
            ("\u{2318}\u{21A9}", "Add the comment to your review"),
        ]),
        ("Window", [
            ("\u{2303}\u{2318}S", "File list"),
            ("\u{2325}\u{2318}0", "Review queue"),
            ("\u{2318}R", "Refresh the pull request"),
            ("\u{2318},", "Settings"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ForEach(Self.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(group.title.uppercased())
                        .font(Typography.eyebrow).kerning(0.6)
                        .foregroundStyle(Palette.textTertiary)
                    ForEach(group.rows, id: \.what) { row in
                        HStack(spacing: Spacing.md) {
                            Text(row.keys)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Palette.textStrong)
                                .frame(width: 84, alignment: .leading)
                            Text(row.what).font(Typography.control)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .frame(width: 400, alignment: .leading)
        .background(Palette.floating)
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var model: AppModel
    let text: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.octagon.fill")
            Text(text).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { model.errorBanner = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .font(Typography.control)
        .foregroundStyle(Palette.removedText)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.removed.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.removed.opacity(0.3)).frame(height: 1) }
    }
}

// MARK: - Resizing

/// A hairline between two columns that drags one of them wider or narrower.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// True when dragging right should grow the column (it sits to the left).
    let growsTrailing: Bool
    @State private var startWidth: Double?
    @State private var pushedCursor = false

    var body: some View {
        Rectangle()
            .fill(startWidth == nil ? Palette.hairline : Palette.accent.opacity(0.6))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { setCursor($0) }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                let delta = Double(value.translation.width) * (growsTrailing ? 1 : -1)
                                width = min(range.upperBound, max(range.lowerBound, start + delta))
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .onDisappear { setCursor(false) }
            .zIndex(1)
    }

    /// `NSCursor.push()` and `pop()` drive a global stack, so every push has
    /// to be matched by exactly one pop — see `SplitHandle` in the diff view.
    private func setCursor(_ inside: Bool) {
        guard inside != pushedCursor else { return }
        pushedCursor = inside
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
}

// MARK: - Window

/// Makes the titlebar part of the content.
///
/// The tab bar is drawn by the app under a transparent titlebar. AppKit lays
/// the traffic lights out for its own 28-32pt titlebar, which leaves them
/// riding high in a 52pt bar, so they are moved to its midline — and moved
/// again whenever AppKit puts them back, which it does on every resize.
///
/// An empty unified `NSToolbar` would centre them for free, but from macOS 26
/// the toolbar paints its own backing over whatever lies beneath it, and the
/// tab bar disappeared under it.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarSeparatorStyle = .none
            window.toolbar = nil

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window,
                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeTrafficLights() }
                }
            }
            placeTrafficLights()
            // Once more after the first layout pass, which resets them.
            DispatchQueue.main.async { [weak self] in self?.placeTrafficLights() }
        }

        private func placeTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let mini = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let container = close.superview?.superview else { return }
            let height = Chrome.topBar
            var frame = container.frame
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame

            let spacing = mini.frame.minX - close.frame.minX
            for (index, button) in [close, mini, zoom].enumerated() {
                button.setFrameOrigin(NSPoint(x: 20 + CGFloat(index) * spacing,
                                              y: (height - button.frame.height) / 2))
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
