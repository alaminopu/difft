import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    let check: (gh: Bool, ghAuth: Bool, claude: Bool)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Difft needs these tools").font(.title2)
            row(ok: check.gh, label: "GitHub CLI installed", fix: "brew install gh")
            row(ok: check.ghAuth, label: "GitHub CLI authenticated", fix: "gh auth login")
            row(ok: check.claude, label: "Claude Code installed", fix: "https://docs.anthropic.com/claude-code")
            Button("Re-check") { Task { await model.checkTools() } }
        }
        .padding(40)
    }

    private func row(ok: Bool, label: String, fix: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
            if !ok { Text(fix).font(.caption.monospaced()).textSelection(.enabled) }
        }
    }
}
