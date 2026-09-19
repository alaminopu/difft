import SwiftUI
import DifftUI

/// Shown until the tools Difft shells out to are present.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    let check: (gh: Bool, ghAuth: Bool, claude: Bool)
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Three things before the first review")
                    .font(Typography.pageTitle).foregroundStyle(Palette.textStrong)
                Text("Difft drives tools you already have rather than holding tokens of its own. "
                     + "It checks for them at launch.")
                    .font(Typography.body).foregroundStyle(Palette.textSecondary)
                    .lineSpacing(Typography.bodyLineSpacing)
            }
            VStack(spacing: 0) {
                row(ok: check.gh, label: "GitHub CLI",
                    detail: "Fetches pull requests and posts your review.",
                    fix: "brew install gh")
                Rectangle().fill(Palette.hairline).frame(height: 1)
                row(ok: check.ghAuth, label: "GitHub CLI signed in",
                    detail: "So requests are made as you.",
                    fix: "gh auth login")
                Rectangle().fill(Palette.hairline).frame(height: 1)
                row(ok: check.claude, label: "Claude Code",
                    detail: "Runs the walkthrough, the review, and answers questions.",
                    fix: "https://docs.anthropic.com/claude-code")
            }
            .card()
            HStack(spacing: Spacing.md) {
                Button("Check again") {
                    checking = true
                    Task {
                        await model.checkTools()
                        checking = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(Spacing.xl * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }

    private func row(ok: Bool, label: String, detail: String, fix: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16))
                .foregroundStyle(ok ? Palette.added : Palette.amber)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(label).font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
                Text(detail).font(Typography.control).foregroundStyle(Palette.textSecondary)
                if !ok {
                    HStack(spacing: Spacing.sm) {
                        Text(fix)
                            .font(Typography.identifier).foregroundStyle(Palette.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, Spacing.sm).padding(.vertical, 3)
                            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 5))
                        Button("Copy") { AppModel.copy(fix) }.buttonStyle(QuietButtonStyle())
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
    }
}
