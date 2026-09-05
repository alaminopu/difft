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
