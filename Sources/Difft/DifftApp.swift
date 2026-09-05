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
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(appearance.colorScheme)
        }
        .commands { DifftCommands(model: model) }

        Settings {
            SettingsView()
        }
    }
}

/// Menu-bar commands. These live in the View menu rather than as hidden
/// buttons in the window so the shortcuts are discoverable — a keystroke
/// nobody can find is a feature nobody uses.
struct DifftCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("All Review Comments") {
                model.session?.showCommits = false
                model.session?.showComments = true
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.session == nil)

            Button("All Commits") {
                model.session?.showComments = false
                model.closeCommit()
                model.session?.showCommits = true
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
        // A commit SHA in a comment opens in the diff viewer. Every other
        // link still goes to the browser, so this handles only our scheme
        // and declines the rest.
        .environment(\.openURL, OpenURLAction { url in
            guard let sha = CommitReference.sha(from: url) else { return .systemAction }
            Task { await model.openCommit(sha: sha) }
            return .handled
        })
        .onAppear { syncHighlighter() }
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
