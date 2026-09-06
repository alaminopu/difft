import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// The PR walkthrough as its own centre pane.
///
/// This used to answer into the assistant chat, where a structured
/// explanation arrived as one long message, could not be scanned, and
/// scrolled away behind the next question. Here every part is addressable:
/// areas group the change by behaviour, and each anchor opens the file at
/// the line it names.
struct ExplainView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ReviewSession
    /// Held directly, not reached through `model`. `AgentController` is a
    /// nested ObservableObject, so its changes do not republish through
    /// `AppModel` — reading `model.agent.toolActivity` rendered the live tool
    /// log exactly once, empty, and never again.
    @ObservedObject var controller: AgentController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            OverviewBackButton()
            Divider().frame(height: 14)
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
                .imageScale(.small)
            Text("Explain diff").font(Typography.sectionTitle)
            if let e = session.data.explanation {
                Text(provenance(e))
                    .font(Typography.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            if case .running(let label) = session.agentState, label == "Explaining" {
                ProgressView().controlSize(.small)
                Button("Stop") { controller.cancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.callout)
            } else if session.data.explanation != nil {
                Button {
                    Task { await model.explainDiff(force: true) }
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(!session.agentState.canStart)
                .help("Run the walkthrough again against the current head")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// "2 minutes ago · a1b2c3d", plus a warning when the branch has moved on
    /// since — a walkthrough of code that is no longer there is worse than
    /// none, so it has to say so.
    private func provenance(_ e: DiffExplanation) -> String {
        var parts = [Self.age(of: e.generatedAt)]
        if let sha = e.headSHA { parts.append(String(sha.prefix(7))) }
        if isStale(e) { parts.append("head has moved since") }
        return parts.joined(separator: " · ")
    }

    /// `RelativeDateTimeFormatter` renders a just-finished run as "in 0
    /// seconds" — future tense, and a rounding artefact of the run's own
    /// duration. Below a minute there is nothing useful to say but "just now".
    static func age(of date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    private func isStale(_ e: DiffExplanation) -> Bool {
        guard let was = e.headSHA, let now = model.commits.first?.sha else { return false }
        return was != now
    }

    // MARK: - Body

    @ViewBuilder private var content: some View {
        if let explanation = session.data.explanation {
            walkthrough(explanation)
        } else if case .running(let label) = session.agentState, label == "Explaining" {
            running
        } else {
            empty
        }
    }

    private var running: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
            Text("Reading the changed files and their callers…")
                .font(Typography.body)
                .foregroundStyle(.secondary)
            // The tool log is the only sign of progress on a long run; without
            // it a two-minute read looks like a hang.
            if !controller.toolActivity.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.toolActivity.suffix(6)) { call in
                        HStack(spacing: Spacing.xs) {
                            Text(call.name).font(.caption.bold())
                            if let detail = call.detail {
                                Text(detail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: Spacing.md) {
            ContentUnavailableView {
                Label("No walkthrough yet", systemImage: "sparkles")
            } description: {
                Text("Claude reads the changed files and their surroundings, then explains "
                     + "what the PR is for, how the pieces fit, and where the risk sits.")
            }
            if case .failed(let message) = session.agentState {
                Text(message)
                    .font(Typography.meta)
                    .foregroundStyle(Palette.warning)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button {
                Task { await model.explainDiff(force: true) }
            } label: {
                Label("Explain this PR", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.agentState.canStart)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func walkthrough(_ e: DiffExplanation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if !e.summary.isEmpty {
                    Text(e.summary)
                        .font(.title3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !e.motivation.isEmpty {
                    labelled("Why", systemImage: "questionmark.circle") {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(e.motivation)
                                .font(Typography.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            // Marked, not hidden. An intent reconstructed from
                            // the code can be right and can be wrong, and a
                            // reviewer has to know which one they are reading.
                            if e.motivationInferred {
                                Label("Inferred from the code — not stated by the author",
                                      systemImage: "questionmark.diamond")
                                    .font(Typography.meta)
                                    .foregroundStyle(Palette.warning)
                            }
                        }
                    }
                }
                if !e.readFirst.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        sectionTitle("Read this first", systemImage: "target")
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(Array(e.readFirst.enumerated()), id: \.offset) { _, anchor in
                                AnchorRow(anchor: anchor, onOpen: open)
                            }
                        }
                        .padding(Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.activeChip, in: RoundedRectangle(cornerRadius: Radius.lg))
                    }
                }
                if !e.areas.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        sectionTitle("Walkthrough", systemImage: "list.bullet.indent")
                        ForEach(Array(e.areas.enumerated()), id: \.offset) { index, area in
                            AreaCard(index: index + 1, area: area, onOpen: open)
                        }
                    }
                }
                if !e.risks.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        sectionTitle("Worth a closer look", systemImage: "exclamationmark.triangle")
                        ForEach(Array(e.risks.enumerated()), id: \.offset) { _, risk in
                            RiskRow(risk: risk, onOpen: open)
                        }
                    }
                }
                if !e.mechanical.isEmpty {
                    labelled("Mechanical, skippable", systemImage: "arrow.left.arrow.right") {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            ForEach(Array(e.mechanical.enumerated()), id: \.offset) { _, item in
                                Text("• " + item)
                                    .font(Typography.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !e.quiz.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        sectionTitle("Before you approve", systemImage: "checkmark.circle")
                        Text("You do not pass on code whose explanation you cannot give. "
                             + "If one of these is a guess, go back to the diff.")
                            .font(Typography.meta).foregroundStyle(.secondary)
                        ForEach(Array(e.quiz.enumerated()), id: \.offset) { index, q in
                            QuizCard(index: index + 1, question: q)
                        }
                    }
                }
                if !e.outOfScope.isEmpty {
                    labelled("Not in this PR", systemImage: "minus.circle") {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(Array(e.outOfScope.enumerated()), id: \.offset) { _, item in
                                Text("• " + item)
                                    .font(Typography.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            // Long prose is unreadable edge to edge; cap the measure and
            // centre it the way the rest of the app caps its content.
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        // A fresh run replaces the centred spinner with this scroll view, and
        // SwiftUI carried the old offset over — the finished walkthrough
        // landed at the bottom, on "Not in this PR". A new identity per run
        // starts it at the top, where the summary is.
        .id(e.generatedAt)
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: systemImage).imageScale(.small)
            Text(text)
        }
        .font(Typography.sectionTitle)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func labelled<Content: View>(
        _ title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionTitle(title, systemImage: systemImage)
            content()
        }
    }

    /// Opens the file an anchor names, focused on its line.
    private func open(_ anchor: ExplainAnchor) {
        guard model.files.contains(where: { $0.path == anchor.file }) else { return }
        session.selectedLines = anchor.line.map { $0...$0 }
        session.selectedFile = anchor.file
        session.pane = .diff
    }
}

/// One slice of the change: what it is, which files carry it, and the exact
/// lines worth opening.
private struct AreaCard: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let area: ExplainArea
    let onOpen: (ExplainAnchor) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text("\(index)")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if !area.title.isEmpty {
                    Text(area.title)
                        .font(Typography.sectionTitle)
                        .textSelection(.enabled)
                }
                if !area.detail.isEmpty {
                    Text(area.detail)
                        .font(Typography.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !area.files.isEmpty {
                    FileChips(paths: area.files) { path in
                        onOpen(ExplainAnchor(file: path, line: nil, what: ""))
                    }
                }
                ForEach(Array(area.anchors.enumerated()), id: \.offset) { _, anchor in
                    AnchorRow(anchor: anchor, onOpen: onOpen)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Palette.cardBorder)
                .allowsHitTesting(false)
        }
    }
}

/// The files an area touches, each one a way into the diff. Paths the diff
/// does not contain are shown but not clickable — the agent can name a file
/// it only read for context.
private struct FileChips: View {
    @EnvironmentObject var model: AppModel
    let paths: [String]
    let onOpen: (String) -> Void

    var body: some View {
        FlowLayout(spacing: Spacing.xs) {
            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                let known = model.files.contains { $0.path == path }
                Button { onOpen(path) } label: {
                    Text(String(path.split(separator: "/").last ?? Substring(path)))
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(known ? 0.6 : 0.25),
                                    in: RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
                .foregroundStyle(known ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .disabled(!known)
                .help(known ? path : "\(path) — not part of this diff")
            }
        }
    }
}

private struct AnchorRow: View {
    @EnvironmentObject var model: AppModel
    let anchor: ExplainAnchor
    let onOpen: (ExplainAnchor) -> Void

    var body: some View {
        let known = model.files.contains { $0.path == anchor.file }
        Button { onOpen(anchor) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: "arrow.right.circle")
                    .imageScale(.small)
                    .foregroundStyle(known ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                Text(location)
                    .font(.caption.monospaced())
                    .foregroundStyle(known ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(anchor.what)
                    .font(Typography.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!known)
        .help(known ? "Open \(location)" : "\(anchor.file) is not part of this diff")
    }

    private var location: String {
        let name = String(anchor.file.split(separator: "/").last ?? Substring(anchor.file))
        return anchor.line.map { "\(name):\($0)" } ?? name
    }
}

private struct RiskRow: View {
    @EnvironmentObject var model: AppModel
    let risk: ExplainAnchor
    let onOpen: (ExplainAnchor) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(risk.what)
                    .font(Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !risk.file.isEmpty {
                    AnchorRow(anchor: ExplainAnchor(file: risk.file, line: risk.line, what: ""),
                              onOpen: onOpen)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Palette.warning.opacity(0.35))
                .allowsHitTesting(false)
        }
    }
}

/// One gate question. Answering reveals whether it was right and why —
/// the explanation is the point, so it shows either way.
private struct QuizCard: View {
    let index: Int
    let question: QuizQuestion
    @State private var picked: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("\(index)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                Text(question.question)
                    .font(Typography.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
                Button {
                    // First answer stands. Letting it be changed after the
                    // reveal turns a check on yourself into a guessing game.
                    if picked == nil { picked = i }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(systemName: marker(for: i))
                            .foregroundStyle(markerColor(for: i))
                            .imageScale(.small)
                        Text(option)
                            .font(Typography.body)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Spacing.xxs)
                    .padding(.horizontal, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: i), in: RoundedRectangle(cornerRadius: Radius.sm))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(picked != nil)
            }
            if picked != nil, !question.why.isEmpty {
                Text(question.why)
                    .font(Typography.meta).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.xxs)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Palette.cardBorder)
                .allowsHitTesting(false)
        }
    }

    private var isAnswered: Bool { picked != nil }

    private func marker(for i: Int) -> String {
        guard isAnswered else { return "circle" }
        if i == question.answer { return "checkmark.circle.fill" }
        return i == picked ? "xmark.circle.fill" : "circle"
    }

    private func markerColor(for i: Int) -> Color {
        guard isAnswered else { return .secondary }
        if i == question.answer { return Palette.added }
        return i == picked ? Palette.removed : .secondary
    }

    private func background(for i: Int) -> Color {
        guard isAnswered else { return .clear }
        if i == question.answer { return Palette.added.opacity(0.12) }
        return i == picked ? Palette.removed.opacity(0.12) : .clear
    }
}
