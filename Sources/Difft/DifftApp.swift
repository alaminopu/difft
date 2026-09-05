import SwiftUI
import DifftUI

@main
struct DifftApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var highlighter = HighlightService()

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
        }
        .commands { DifftCommands(model: model) }
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
                model.session?.showComments = true
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.session == nil)

            Button("Back to Pull Request Overview") {
                model.session?.showComments = false
                model.session?.selectedFile = nil
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
        .onAppear { highlighter.setDark(colorScheme == .dark) }
        .onChange(of: colorScheme) { _, scheme in highlighter.setDark(scheme == .dark) }
    }
}
