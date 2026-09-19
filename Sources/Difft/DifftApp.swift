import SwiftUI
import DifftCore
import DifftUI

/// Appearance the user picked, independent of the system setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }

    var label: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil hands the decision back to macOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@main
struct DifftApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var highlighter = HighlightService()
    @AppStorage(PrefKey.appearance) private var appearance = AppAppearance.system

    init() {
        NSApplication.shared.setActivationPolicy(.regular) // needed when run via `swift run`
    }

    var body: some Scene {
        WindowGroup("Difft") {
            RootView()
                .environmentObject(model)
                .environmentObject(highlighter)
                .task { await model.checkTools() }
                .task { await model.loadCurrentUser() }
                #if DEBUG
                .task { await DebugLaunch.run(model) }
                #endif
                .onAppear { RunNotifier.shared.start() }
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Palette.accent)
        }
        // The tab bar is the titlebar; see WindowConfigurator.
        .windowStyle(.hiddenTitleBar)
        .commands { DifftCommands(model: model) }

        Settings {
            SettingsView()
                // The preview draws a real diff, which needs the highlighter.
                .environmentObject(highlighter)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

/// Menu-bar commands. These live in the View menu rather than as hidden
/// buttons in the window so the shortcuts are discoverable — a keystroke
/// nobody can find is a feature nobody uses.
struct DifftCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        // File menu. Choosing a repository was only reachable from a small
        // icon in the sidebar header, which is not where anyone looks for it.
        CommandGroup(after: .newItem) {
            Button("Open Repository…") {
                model.chooseRepository()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Show or Hide File List") {
                NotificationCenter.default.post(name: .difftToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Button("Show or Hide Review Queue") {
                NotificationCenter.default.post(name: .difftTogglePanel, object: nil)
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(model.session == nil)

            Divider()

            Button("Jump to File or Line\u{2026}") {
                NotificationCenter.default.post(name: .difftJump, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model.session == nil)

            // The tabs, in bar order. Navigation only: unlike the commands
            // below, these never start an agent run.
            ForEach(ReviewTab.allCases) { tab in
                Button(tab.label) { model.show(tab) }
                    .keyboardShortcut(KeyEquivalent(tab.shortcut), modifiers: .command)
                    .disabled(model.session == nil)
            }

            Divider()
            Button("All Review Comments") {
                model.session?.pane = .comments
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.session == nil)

            Button("Explain Diff") {
                Task { await model.explainDiff() }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.session == nil)

            Button("Your Review") {
                model.closeCommit()
                model.session?.pane = .pending
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(model.session == nil)

            Button("Review Findings") {
                Task { await model.review() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.session == nil)

            Button("All Commits") {
                model.closeCommit()
                model.session?.pane = .commits
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model.session == nil)

            Button("Back to Pull Request Overview") {
                model.showOverview()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(model.session == nil)

            Divider()

            Button("Refresh Pull Request") {
                Task { await model.refreshPR() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.session == nil || model.isRefreshing)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var highlighter: HighlightService
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(PrefKey.appearance) private var appearance = AppAppearance.system
    @AppStorage(PrefKey.codeFontFamily) private var codeFontFamily = CodeFont.systemFamily
    @AppStorage(PrefKey.diffFontSize) private var diffFontSize = DiffMetrics.defaultFontSize
    @AppStorage(PrefKey.syntaxTheme) private var syntaxTheme = SyntaxTheme.atomOne
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    /// Resolved from the preference rather than read from the environment, so
    /// the syntax palette cannot lag a scheme the user forced.
    private var isDark: Bool {
        switch appearance {
        case .system: return colorScheme == .dark
        case .light: return false
        case .dark: return true
        }
    }

    var body: some View {
        Group {
            if let check = model.toolCheck, !(check.gh && check.ghAuth && check.claude) {
                OnboardingView(check: check)
            } else {
                MainSplitView()
            }
        }
        // Keep the syntax palette in lockstep with the real appearance —
        // NSApp.effectiveAppearance lies during early launch.
        .environment(\.repoSlug, model.repoSlug)
        // A commit SHA in a comment opens in the diff viewer.
        //
        // Everything else is handed to the system ONLY if it is a web link.
        // PR descriptions and review comments are attacker-controlled markdown
        // on a PR from a fork, and `.systemAction` on an arbitrary scheme is
        // LaunchServices opening whatever is registered for it — file://,
        // another app's custom scheme. Web links go out; the rest is inert.
        .environment(\.openURL, OpenURLAction { url in
            if let sha = CommitReference.sha(from: url) {
                Task { await model.openCommit(sha: sha) }
                return .handled
            }
            return DifftURLPolicy.allowsOpening(url) ? .systemAction : .discarded
        })
        .onAppear { syncHighlighter() }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["DIFFT_SETTINGS"] != nil { openSettings() }
        }
        #endif
        .onChange(of: colorScheme) { _, _ in highlighter.setDark(isDark) }
        .onChange(of: appearance) { _, _ in highlighter.setDark(isDark) }
        // The font has to be pushed into the highlighter, not applied around
        // it: Highlightr stamps its own font onto every span, and that beats
        // the view's .font modifier.
        .onChange(of: codeFontFamily) { _, _ in syncCodeFont() }
        .onChange(of: diffFontSize) { _, _ in syncCodeFont() }
        .onChange(of: syntaxTheme) { _, theme in highlighter.setTheme(theme) }
    }

    private func syncHighlighter() {
        highlighter.setTheme(syntaxTheme)
        highlighter.setDark(isDark)
        syncCodeFont()
    }

    private func syncCodeFont() {
        highlighter.setCodeFont(family: codeFontFamily, size: CGFloat(diffFontSize))
    }
}

#if DEBUG
/// Drives a debug build straight to a screen, for checking a design change
/// without clicking through to it:
///
///     DIFFT_OPEN_PR=6022 DIFFT_OPEN_PATH=form/main.py DIFFT_OPEN_LINE=120 swift run Difft
///
/// Compiled out of release builds.
enum DebugLaunch {
    @MainActor static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        if env["DIFFT_HOME"] != nil { model.closeRepository(); return }
        guard let number = env["DIFFT_OPEN_PR"].flatMap(Int.init) else { return }
        // The list page loads the same query; wait for whichever lands.
        for _ in 0..<60 where model.prs.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let pr = model.prs.first(where: { $0.number == number }) else { return }
        await model.openPR(pr)
        if let index = env["DIFFT_OPEN_FILE"].flatMap(Int.init), model.files.indices.contains(index) {
            model.open(file: model.files[index].path)
        }
        if let suffix = env["DIFFT_OPEN_PATH"],
           let file = model.files.first(where: { $0.path.hasSuffix(suffix) }) {
            // Threads load after the diff; wait so the line can be focused.
            for _ in 0..<40 where model.isLoadingDetails {
                try? await Task.sleep(for: .milliseconds(500))
            }
            model.open(file: file.path, line: env["DIFFT_OPEN_LINE"].flatMap(Int.init))
        }
        if let tab = env["DIFFT_TAB"].flatMap(ReviewTab.init(rawValue:)) { model.show(tab) }
        if env["DIFFT_PANE"] == "pending" { model.session?.pane = .pending }
        if env["DIFFT_JUMP"] != nil {
            NotificationCenter.default.post(name: .difftJump, object: nil)
        }
    }
}
#endif
