import SwiftUI
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
    @AppStorage("appearance") private var appearance = AppAppearance.system

    init() {
        NSApplication.shared.setActivationPolicy(.regular) // needed when run via `swift run`
    }

    var body: some Scene {
        WindowGroup("Difft") {
            RootView()
                .environmentObject(model)
                .environmentObject(highlighter)
                .task { await model.checkTools() }
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(appearance.colorScheme)
        }
        .commands { DifftCommands(model: model) }
    }
}

/// Menu-bar commands. These live in the View menu rather than as hidden
/// buttons in the window so the shortcuts are discoverable — a keystroke
/// nobody can find is a feature nobody uses.
struct DifftCommands: Commands {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }

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
                model.session?.showComments = false
                model.session?.showCommits = false
                model.session?.selectedFile = nil
                model.closeCommit()
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
    @AppStorage("appearance") private var appearance = AppAppearance.system

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
        .onAppear { highlighter.setDark(isDark) }
        .onChange(of: colorScheme) { _, _ in highlighter.setDark(isDark) }
        .onChange(of: appearance) { _, _ in highlighter.setDark(isDark) }
    }
}
