import SwiftUI
import DifftServices
import DifftUI

/// The notes staged so far, and the one action that sends them.
///
/// GitHub's review model is a batch: write line notes as you read, then submit
/// them together with a verdict. Difft posted each note the moment it was
/// written, which sends the author a notification per note, cannot say
/// "approved" or "changes requested" at all, and leaves half a review behind
/// if one call fails.
struct PendingReviewView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    @State private var verdict: ReviewVerdict = .comment
    @State private var summary: String = ""
    @State private var editing: DraftComment?

    private var drafts: [DraftComment] { session.data.draftComments }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Always the form. With no notes this used to show only an empty
            // state, so a clean PR could not be approved from here at all —
            // and approving without comment is the commonest review there is.
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { summary = session.data.draftReviewBody }
        .sheet(item: $editing) { draft in
            DraftEditSheet(draft: draft) { body in
                model.updateDraft(draft, body: body)
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    private var header: some View {
        PaneHeader {
            Text("Your review").font(Typography.sectionTitle).foregroundStyle(Palette.textStrong)
            if !drafts.isEmpty {
                Text("\(drafts.count) note\(drafts.count == 1 ? "" : "s") staged")
                    .font(Typography.meta).foregroundStyle(Palette.textTertiary)
            }
        } trailing: {
            if model.isSubmittingReview { ProgressView().controlSize(.small).scaleEffect(0.8) }
        }
    }

    private var empty: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "square.and.pencil").foregroundStyle(Palette.textTertiary)
            Text("No line notes yet. Select lines in a file and press C, or right-click and "
                 + "choose Comment on Selection. They gather here until you submit. "
                 + "You can also submit a verdict on its own.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Typography.control)
        .foregroundStyle(Palette.textSecondary)
        .lineSpacing(Typography.bodyLineSpacing)
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if drafts.isEmpty { empty }
                ForEach(byFile, id: \.path) { group in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(group.path)
                            .font(Typography.path).foregroundStyle(Palette.textSecondary)
                            .lineLimit(1).truncationMode(.head)
                        ForEach(group.drafts) { draft in
                            DraftCard(draft: draft,
                                      onEdit: { editing = draft },
                                      onRemove: { model.removeDraft(draft) })
                        }
                    }
                }
                submitBox
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Notes grouped by file, in the order they were written.
    private var byFile: [(path: String, drafts: [DraftComment])] {
        var order: [String] = []
        var grouped: [String: [DraftComment]] = [:]
        for draft in drafts {
            if grouped[draft.path] == nil { order.append(draft.path) }
            grouped[draft.path, default: []].append(draft)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private var submitBox: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Summary").font(Typography.sectionTitle)
            ComposerEditor(text: $summary, minHeight: 90)
                .onChange(of: summary) { _, new in model.setDraftReviewBody(new) }

            SegmentedControl(selection: $verdict,
                             options: ReviewVerdict.allCases.map { ($0, $0.label) })

            HStack(alignment: .firstTextBaseline) {
                Text(verdict.detail).font(Typography.meta).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Submit review") {
                    Task { await model.submitReview(verdict) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isSubmittingReview)
            }
        }
        .padding(Spacing.lg)
        .card()
    }
}

private struct DraftCard: View {
    let draft: DraftComment
    let onEdit: () -> Void
    let onRemove: () -> Void

    private var anchor: String {
        guard let start = draft.startLine, start < draft.line else { return "Line \(draft.line)" }
        return "Lines \(start)–\(draft.line)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(anchor).font(Typography.badge).foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Edit", action: onEdit).buttonStyle(QuietButtonStyle())
                Button("Remove", action: onRemove)
                    .buttonStyle(QuietButtonStyle(tint: Palette.removedText))
            }
            MarkdownBodyView(text: draft.body)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Copy") { AppModel.copy(draft.body) }
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

private struct DraftEditSheet: View {
    let draft: DraftComment
    var onSave: (String) -> Void
    var onCancel: () -> Void
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Edit note").font(Typography.sectionTitle)
            ComposerEditor(text: $text, minHeight: 140)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 520)
        .onAppear { text = draft.body }
    }
}
