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
            Divider()
            if drafts.isEmpty && session.data.draftReviewBody.isEmpty {
                empty
            } else {
                content
            }
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
        HStack(spacing: Spacing.sm) {
            OverviewBackButton()
            Divider().frame(height: 14)
            Image(systemName: "checkmark.seal").foregroundStyle(Color.accentColor).imageScale(.small)
            Text("Your review").font(Typography.sectionTitle)
            if !drafts.isEmpty {
                Text("\(drafts.count) note\(drafts.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSubmittingReview { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(.bar)
    }

    private var empty: some View {
        ContentUnavailableView(
            "No notes yet", systemImage: "square.and.pencil",
            description: Text("Select lines in a file, right-click, and choose "
                              + "\"Comment on selection\" to start a review. "
                              + "Notes gather here until you submit them together."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(byFile, id: \.path) { group in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(group.path)
                            .font(Typography.path).foregroundStyle(.secondary)
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
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            TextEditor(text: $summary)
                .font(Typography.body)
                .frame(minHeight: 80)
                .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Palette.cardBorder) }
                .onChange(of: summary) { _, new in model.setDraftReviewBody(new) }

            Picker("Verdict", selection: $verdict) {
                ForEach(ReviewVerdict.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .firstTextBaseline) {
                Text(verdict.detail).font(Typography.meta).foregroundStyle(.secondary)
                Spacer()
                Button("Submit review") {
                    Task { await model.submitReview(verdict) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSubmittingReview)
            }
        }
        .padding(Spacing.md)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Palette.cardBorder) }
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
                Text(anchor).font(Typography.badge).foregroundStyle(.secondary)
                Spacer()
                Button("Edit", action: onEdit).buttonStyle(.plain)
                    .font(.caption).foregroundStyle(Color.accentColor)
                Button("Remove", action: onRemove).buttonStyle(.plain)
                    .font(.caption).foregroundStyle(.red)
            }
            MarkdownBodyView(text: draft.body)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.sm))
        .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Palette.cardBorder) }
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
            TextEditor(text: $text)
                .font(Typography.body)
                .frame(minHeight: 140)
                .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Palette.cardBorder) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 520)
        .onAppear { text = draft.body }
    }
}
