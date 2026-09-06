import SwiftUI
import DifftCore
import DifftServices

public struct FileDiffView: View {
    public let file: FileDiff
    @Binding public var layout: DiffLayout
    @Binding public var selection: LineSelection?
    public let fontSize: Int
    /// New-file line number to scroll to and select on appear (e.g. from a
    /// findings click). Falls back to old-number matching for deletions.
    public let focusLine: Int?
    /// Called after the focus target has been applied so the owner can clear
    /// it — otherwise a stale target re-fires on later file switches.
    public var onFocused: () -> Void
    public let comments: [ReviewComment]
    public var onAsk: (String, String) -> Void  // (selectedText, contextChip)

    // Old/new column balance, draggable via the center divider. Persisted
    // globally (not per file) so it survives file switches and relaunches.
    @AppStorage("diffSplitFraction") private var split = 0.5

    fileprivate enum DiffItem: Identifiable, Sendable {
        case hunkHeader(index: Int, text: String)
        case row(SideBySideRow)
        case comment(ReviewComment)
        var id: String {
            switch self {
            case .hunkHeader(let i, _): return "h\(i)"
            case .row(let r): return "r\(r.id)"
            case .comment(let c): return "c\(c.id)"
            }
        }
    }

    fileprivate struct Built: Sendable {
        var items: [DiffItem] = []
        var allRows: [SideBySideRow] = []
        var changeBlocks: [ChangeBlock] = []
        /// Widest line number in the file, in digits. Computed here because
        /// finding it walks every line: as a computed property read once per
        /// visible row it cost ~34ms per body pass on a 10k-line file.
        var digits = 2
        var key = ""
    }
    /// Heavy row/anchor/rail construction, cached per (file, layout,
    /// comments) — rebuilding it in init made every body re-evaluation
    /// (each frame of the panel's width animation) an O(file) rebuild.
    @State private var built = Built()

    // Drag-to-select over rows: visible rows report their frames in the
    // "diffSpace" coordinate space; a container-level drag maps y positions
    // back to row ids.
    /// Row frames live in a reference box rather than `@State` on purpose.
    ///
    /// Scrolling changes every visible row's frame in `diffSpace`, so the
    /// preference fires on essentially every scroll frame. Storing that in
    /// `@State` re-rendered this whole view each time — and the frames are
    /// only ever read inside the drag gesture, where a re-render buys nothing.
    @State private var rowFrames = RowFrameStore()
    @State private var dragAnchorRow: Int?
    /// Trailing strip the macOS scroller floats in. Drag-to-select ignores it
    /// so grabbing the thumb doesn't also sweep a selection. Legacy scrollers
    /// are 15pt and overlay ones narrower; 16 covers both.
    private static let scrollerWidth: CGFloat = 16
    /// Line range a new comment is being written against, nil when not
    /// composing.
    @State private var composing: CommentTarget?

    public var onReplyComment: (ReviewComment, String) -> Void = { _, _ in }
    public var onResolveComment: (ReviewComment) -> Void = { _ in }
    /// nil for a comment that is not the signed-in user's.
    public var onEditComment: ((ReviewComment) -> ((String) -> Void)?)?
    /// (path, startLine, endLine, body). nil disables commenting entirely,
    /// which is what a single-commit diff wants — its line numbers are not
    /// the ones GitHub anchors PR comments to.
    public var onAddComment: ((Int, Int, String) -> Void)?

    public init(file: FileDiff, layout: Binding<DiffLayout>, selection: Binding<LineSelection?>,
                fontSize: Int = DiffMetrics.defaultFontSize, focusLine: Int? = nil, comments: [ReviewComment] = [],
                onFocused: @escaping () -> Void = {}, onAsk: @escaping (String, String) -> Void,
                onReplyComment: @escaping (ReviewComment, String) -> Void = { _, _ in },
                onResolveComment: @escaping (ReviewComment) -> Void = { _ in },
                onEditComment: ((ReviewComment) -> ((String) -> Void)?)? = nil,
                onAddComment: ((Int, Int, String) -> Void)? = nil) {
        self.onReplyComment = onReplyComment
        self.onResolveComment = onResolveComment
        self.onEditComment = onEditComment
        self.onAddComment = onAddComment
        self.file = file; self._layout = layout; self._selection = selection
        self.fontSize = fontSize; self.focusLine = focusLine
        self.onFocused = onFocused; self.onAsk = onAsk
        self.comments = comments
    }


    nonisolated fileprivate static func build(file: FileDiff, sideBySide: Bool,
                                  comments: [ReviewComment], key: String) -> Built {
        var items: [DiffItem] = []
        var rows: [SideBySideRow] = []
        var base = 0
        // A full-context diff is one hunk spanning the whole file; its @@
        // header is noise there.
        let fullFile = file.hunks.count == 1
            && (file.hunks[0].lines.first.flatMap { $0.oldNumber ?? $0.newNumber } ?? 0) <= 1
        for (i, hunk) in file.hunks.enumerated() {
            if !fullFile { items.append(.hunkHeader(index: i, text: hunk.header)) }
            let local = sideBySide ? RowPairer.rows(for: [hunk]) : RowPairer.unifiedRows(for: [hunk])
            for r in local {
                let remapped = SideBySideRow(id: base + r.id, left: r.left, right: r.right)
                items.append(.row(remapped))
                rows.append(remapped)
            }
            base += local.count
        }
        // Anchor review comments under their row: LEFT comments match old
        // line numbers, RIGHT (the default) match new ones. Outdated comments
        // with no line are skipped.
        for c in comments {
            guard let line = c.line else { continue }
            let matches: (SideBySideRow) -> Bool = c.side == "LEFT"
                ? { $0.left?.oldNumber == line || $0.right?.oldNumber == line }
                : { $0.right?.newNumber == line || $0.left?.newNumber == line }
            guard let row = rows.first(where: matches),
                  let idx = items.firstIndex(where: { $0.id == "r\(row.id)" }) else { continue }
            var insertAt = idx + 1
            while insertAt < items.count, case .comment = items[insertAt] { insertAt += 1 }
            items.insert(.comment(c), at: insertAt)
        }
        // Runs of consecutive changed rows for the overview rail.
        var blocks: [ChangeBlock] = []
        let total = CGFloat(max(rows.count, 1))
        var i = 0
        while i < rows.count {
            let kind = ChangeBlock.kind(of: rows[i])
            if kind == nil { i += 1; continue }
            let start = i
            var hasAdd = false, hasDel = false
            while i < rows.count, let k = ChangeBlock.kind(of: rows[i]) {
                hasAdd = hasAdd || k == .addition
                hasDel = hasDel || k == .deletion || rows[i].left?.kind == .deletion
                i += 1
            }
            let color: Color = (hasAdd && hasDel) ? .orange : hasDel ? .red : .green
            blocks.append(ChangeBlock(rowID: rows[start].id,
                                      fraction: CGFloat(start) / total,
                                      extent: CGFloat(i - start) / total,
                                      color: color))
        }
        return Built(items: items, allRows: rows, changeBlocks: blocks,
                     digits: DiffMetrics.digits(for: file.maxLineNumber), key: key)
    }

    /// Keyed on comment identity and state, not just count: resolving a
    /// comment changes `resolved` without changing the count, and the stale
    /// card used to stay on screen.
    private var buildKey: String {
        let commentKey = comments.map { "\($0.id):\($0.resolved)" }.joined(separator: ",")
        return "\(file.path)|\(layout)|\(commentKey)"
    }

    /// Diff geometry for this file: the gutter is sized from the widest line
    /// number it actually has to show, at the current font size.
    private var metrics: DiffMetrics {
        DiffMetrics(fontSize: CGFloat(fontSize),
                    digits: built.digits,
                    unified: layout == .unified)
    }

    public var body: some View {
        switch file.kind {
        case .binary:
            ContentUnavailableView("Binary file", systemImage: "doc.zipper",
                                   description: Text(file.path))
        default:
            GeometryReader { geo in
                let widths = columnWidths(paneWidth: geo.size.width)
                let leftW = widths.left
                let rightW = widths.right
                // Width the scroll view actually gets. The rail is always
                // reserved, present or not, so switching files doesn't shift
                // the columns sideways.
                let contentW = geo.size.width - DiffMetrics.railWidth
                ScrollViewReader { proxy in
                  HStack(spacing: 0) {
                    ScrollView(.vertical) {
                        let language = HighlightService.language(forPath: file.path)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(built.items) { item in
                                switch item {
                                case .hunkHeader(_, let text):
                                    HunkHeaderView(text: text, metrics: metrics)
                                case .comment(let c):
                                    CommentCardView(comment: c,
                                                    onReply: { body in onReplyComment(c, body) },
                                                    onResolve: { onResolveComment(c) },
                                                    onEdit: onEditComment?(c))
                                case .row(let row):
                                    DiffRowView(row: row, layout: layout,
                                                language: language,
                                                isSelected: selection.map { $0.range.contains(row.id) } ?? false,
                                                metrics: metrics,
                                                leftCodeWidth: leftW,
                                                rightCodeWidth: rightW,
                                                onGutterClick: { id, shift in
                                                    selection = SelectionLogic.click(current: selection, rowID: id, extending: shift)
                                                },
                                                onContextAsk: { id in askAbout(rowID: id) },
                                                onContextCopy: { id in copyRows(rowID: id) },
                                                onContextComment: onAddComment == nil
                                                    ? nil : { id in startComment(rowID: id) })
                                        .id(item.id)
                                        .background(GeometryReader { rowGeo in
                                            Color.clear.preference(
                                                key: RowFramesKey.self,
                                                value: [row.id: rowGeo.frame(in: .named("diffSpace"))])
                                        })
                                }
                            }
                        }
                        .frame(width: contentW, alignment: .leading)
                        .onPreferenceChange(RowFramesKey.self) { frames in rowFrames.frames = frames }
                    }
                    .coordinateSpace(name: "diffSpace")
                    // Mouse drag over rows extends the selection line by line
                    // (trackpad two-finger scrolling is a scroll event, not a
                    // drag, so this doesn't fight vertical scrolling).
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named("diffSpace"))
                            .onChanged { value in
                                // The scroller floats over the scroll view's
                                // own trailing edge. Recognising a drag there
                                // meant dragging the thumb also swept a line
                                // selection, and the churn made it stutter.
                                guard value.startLocation.x < contentW - Self.scrollerWidth else { return }
                                if dragAnchorRow == nil {
                                    dragAnchorRow = rowID(atY: value.startLocation.y)
                                }
                                guard let anchor = dragAnchorRow,
                                      let head = rowID(atY: value.location.y) else { return }
                                selection = LineSelection(anchor: anchor, head: head)
                            }
                            .onEnded { _ in dragAnchorRow = nil }
                    )
                    // Beside the scroll view, never over it: as a trailing
                    // overlay the rail sat exactly on top of the macOS
                    // scroller and swallowed every mouse-down aimed at the
                    // thumb, so the bar couldn't be dragged at all.
                    Group {
                        // No rail when changes blanket the file (e.g. a fully
                        // added file) — a wall-to-wall tick navigates nothing.
                        if !built.changeBlocks.isEmpty,
                           built.changeBlocks.reduce(0, { $0 + $1.extent }) < 0.9 {
                            ChangeRailView(blocks: built.changeBlocks) { rowID in
                                // Unanimated: animating a jump across a lazy
                                // 10k-row list realises everything in between.
                                proxy.scrollTo("r\(rowID)", anchor: .center)
                            } onScrub: { ratio in
                                guard !built.allRows.isEmpty else { return }
                                let last = built.allRows.count - 1
                                let idx = min(last, max(0, Int(ratio * CGFloat(built.allRows.count))))
                                proxy.scrollTo("r\(built.allRows[idx].id)", anchor: .top)
                            }
                        }
                    }
                    .frame(width: DiffMetrics.railWidth)
                  }
                    // Rows build asynchronously: applying focus on appear ran
                    // against an empty row set and silently did nothing. Apply
                    // it whenever the built rows (or the target) change.
                    .onChange(of: built.key, initial: true) { _, _ in
                        guard !built.allRows.isEmpty else { return }
                        if focusLine != nil {
                            focusIfNeeded(proxy)
                        } else {
                            scrollToFirstChange(proxy)
                        }
                    }
                    .onChange(of: focusLine) { focusIfNeeded(proxy) }
                }
                .overlay {
                    if layout == .sideBySide, let leftW = leftW {
                        // Anchored to the REAL divider x (left gutter + left column),
                        // which differs from paneWidth*split when widths clamp.
                        // contentW, not geo.size.width: the columns are laid
                        // out in the space left after the rail, so mapping the
                        // drag against the full pane left the divider trailing
                        // the pointer by the rail's width.
                        SplitHandle(split: $split, paneWidth: contentW,
                                    dividerX: leftW + metrics.totalGutter + 0.5)
                    }
                }
            }
            .copyable(selection.map { [SelectionLogic.selectedText(rows: built.allRows, selection: $0)] } ?? [])
            .sheet(item: $composing) { target in
                NewCommentSheet(path: file.path, target: target) { body in
                    onAddComment?(target.startLine, target.endLine, body)
                    composing = nil
                } onCancel: {
                    composing = nil
                }
            }
            .task(id: buildKey) {
                // Off the main actor: a big file builds in background and pops
                // in; body evaluations stay cheap in the meantime.
                let f = file, side = layout == .sideBySide, cs = comments, key = buildKey
                guard built.key != key else { return }
                built = await Task.detached(priority: .userInitiated) {
                    Self.build(file: f, sideBySide: side, comments: cs, key: key)
                }.value
                if focusLine != nil { /* focus re-applied by focusIfNeeded below via onAppear path */ }
            }
            .overlay {
                if built.key.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    /// Right-click "Ask Claude": acts on the current multi-line selection when
    /// the clicked row is inside it, otherwise on the clicked row alone.
    private func effectiveSelection(for rowID: Int) -> LineSelection {
        if let sel = selection, sel.range.contains(rowID) { return sel }
        let sel = LineSelection(anchor: rowID, head: rowID)
        selection = sel
        return sel
    }

    /// Opens the composer for the selected rows.
    ///
    /// GitHub anchors a review comment to a line of the *new* file, so rows
    /// that only exist on the old side (pure deletions) cannot carry one —
    /// the selection is narrowed to the lines that can.
    private func startComment(rowID: Int) {
        let sel = effectiveSelection(for: rowID)
        let newLines = built.allRows
            .filter { sel.range.contains($0.id) }
            .compactMap { $0.right?.newNumber }
        guard let low = newLines.min(), let high = newLines.max() else { return }
        composing = CommentTarget(startLine: low, endLine: high)
    }

    private func askAbout(rowID: Int) {
        let sel = effectiveSelection(for: rowID)
        onAsk(SelectionLogic.selectedText(rows: built.allRows, selection: sel),
              SelectionLogic.contextChip(path: file.path, rows: built.allRows, selection: sel))
    }

    private func copyRows(rowID: Int) {
        let sel = effectiveSelection(for: rowID)
        let text = SelectionLogic.selectedText(rows: built.allRows, selection: sel)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func columnWidths(paneWidth: CGFloat) -> (left: CGFloat?, right: CGFloat?) {
        guard layout == .sideBySide else { return (nil, nil) }
        let gutter = metrics.totalGutter
        // The rail is an overlay on the trailing edge; without reserving it
        // here it covered the last 12pt of the right column, tap target
        // included.
        let usable = paneWidth - DiffMetrics.railWidth
        let left = max(80, usable * CGFloat(split) - gutter)
        let right = max(80, usable * CGFloat(1 - split) - gutter - metrics.dividerWidth)
        return (left, right)
    }

    /// Full-file diffs open on the first changed row rather than line 1.
    private func scrollToFirstChange(_ proxy: ScrollViewProxy) {
        guard let row = built.allRows.first(where: { ($0.left?.kind ?? $0.right?.kind) != .context
            || ($0.right?.kind ?? $0.left?.kind) != .context }) else { return }
        guard row.id > 10 else { return }  // change is near the top already
        proxy.scrollTo("r\(row.id)", anchor: UnitPoint(x: 0, y: 0.25))
    }

    /// Row under a y position in "diffSpace", nearest match when between rows.
    private func rowID(atY y: CGFloat) -> Int? {
        if let hit = rowFrames.frames.first(where: { $0.value.minY <= y && y < $0.value.maxY }) {
            return hit.key
        }
        return rowFrames.frames.min(by: { abs($0.value.midY - y) < abs($1.value.midY - y) })?.key
    }

    /// Scroll to and select the row matching `focusLine` (new-file number
    /// first, old-file as fallback so deleted lines resolve too).
    private func focusIfNeeded(_ proxy: ScrollViewProxy) {
        guard let line = focusLine else { return }
        let row = built.allRows.first { ($0.right ?? $0.left)?.newNumber == line }
            ?? built.allRows.first { ($0.left ?? $0.right)?.oldNumber == line }
        guard let row else { return }
        selection = LineSelection(anchor: row.id, head: row.id)
        withAnimation { proxy.scrollTo("r\(row.id)", anchor: .center) }
        onFocused()
    }
}

/// Markdown-ish body shared by chat messages and comment cards: prose with
/// inline markdown, fenced code blocks monospaced and syntax-highlighted
/// (language auto-detected).
public struct MarkdownBodyView: View {
    public let text: String
    @EnvironmentObject var highlighter: HighlightService
    @AppStorage(PrefKey.codeFontFamily) private var codeFontFamily = CodeFont.systemFamily
    @Environment(\.repoSlug) private var repoSlug

    public init(text: String) { self.text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(CommentBodySegment.parse(text).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let t):
                    // Split out markdown heading lines (inline-only parsing
                    // would show the ### literally).
                    ForEach(Array(Self.headingChunks(t).enumerated()), id: \.offset) { _, chunk in
                        if chunk.isHeading {
                            Text(chunk.text)
                                .font(.headline)
                                .padding(.top, 4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(Self.inline(chunk.text, codeFamily: codeFontFamily, repoSlug: repoSlug))
                                .font(Typography.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .code(let c):
                    ScrollView(.horizontal) {
                        Text(highlighter.highlightedAuto(c))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

extension MarkdownBodyView {
    /// Inline markdown with `backticked spans` actually rendered as code.
    ///
    /// `AttributedString(markdown:)` recognises them and sets
    /// `inlinePresentationIntent = .code`, but nothing acts on that intent, so
    /// inline code came out looking exactly like the prose around it — which
    /// matters in review comments, where half the sentence is identifiers.
    static func inline(_ markdown: String, codeFamily: String,
                       repoSlug: String? = nil) -> AttributedString {
        guard var attr = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(markdown) }

        // Collect first: mutating the string while iterating its runs would
        // invalidate the indices being walked.
        let codeRanges = attr.runs.compactMap {
            $0.inlinePresentationIntent?.contains(.code) == true ? $0.range : nil
        }
        for range in codeRanges {
            attr[range].font = CodeFont.swiftUIFont(family: codeFamily, size: 12)
            attr[range].backgroundColor = Palette.inlineCode
        }
        linkCommitReferences(in: &attr, repoSlug: repoSlug, codeFamily: codeFamily)
        return attr
    }

    /// Turns bare SHAs into links to the commit, the way GitHub does with
    /// "Fixed in d59f520cc".
    ///
    /// Spans already carrying a link or code styling are skipped: a SHA
    /// inside backticks was written as literal text, and one inside an
    /// existing link already goes somewhere.
    private static func linkCommitReferences(in attr: inout AttributedString,
                                             repoSlug: String?, codeFamily: String) {
        // No repo means no PR is open, so there is no worktree to resolve a
        // SHA against and nothing useful a link could do.
        guard repoSlug != nil else { return }
        let plain = String(attr.characters)

        // Applying links shifts nothing, but walking back to front keeps the
        // offsets valid regardless of how attribute runs get split.
        for range in CommitReference.ranges(in: plain).reversed() {
            guard let lo = attr.index(attr.startIndex, offsetByCharacters: range.lowerBound)
                    as AttributedString.Index?,
                  let hi = attr.index(attr.startIndex, offsetByCharacters: range.upperBound)
                    as AttributedString.Index? else { continue }
            let slice = attr[lo..<hi]
            if slice.runs.contains(where: {
                $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true
            }) { continue }

            let sha = String(Array(plain)[range])
            guard let url = CommitReference.url(sha: sha) else { continue }
            attr[lo..<hi].link = url
            attr[lo..<hi].font = CodeFont.swiftUIFont(family: codeFamily, size: 12)
        }
    }

    struct Chunk { let text: String; let isHeading: Bool }
    /// Splits prose into heading lines (#, ##, ###…) and paragraph runs.
    static func headingChunks(_ text: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var para: [String] = []
        func flush() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(Chunk(text: t, isHeading: false)) }
            para = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), let range = trimmed.range(of: "^#{1,6} +", options: .regularExpression) {
                flush()
                chunks.append(Chunk(text: String(trimmed[range.upperBound...]), isHeading: true))
            } else {
                para.append(line)
            }
        }
        flush()
        return chunks
    }
}

/// Inline review-comment card, IntelliJ-style: author, age, body with fenced
/// code blocks rendered as code, plus Reply and Resolve actions.
///
/// `indented` is what the diff view needs and the comments list does not: in
/// the diff the card floats under a code row and is inset to clear the gutter,
/// while in a list it fills its container.
public struct CommentCardView: View {
    let comment: ReviewComment
    var onReply: (String) -> Void = { _ in }
    var onResolve: () -> Void = {}
    /// nil when the comment is not the signed-in user's, which is what hides
    /// the Edit action rather than showing one that would fail.
    var onEdit: ((String) -> Void)?
    var indented: Bool = true
    @State private var replying = false
    @State private var replyText = ""
    @State private var editing = false
    @State private var editText = ""

    public init(comment: ReviewComment,
                onReply: @escaping (String) -> Void = { _ in },
                onResolve: @escaping () -> Void = {},
                onEdit: ((String) -> Void)? = nil,
                indented: Bool = true) {
        self.comment = comment
        self.onReply = onReply
        self.onResolve = onResolve
        self.onEdit = onEdit
        self.indented = indented
    }

    private var age: String {
        let fmt = ISO8601DateFormatter()
        guard let date = fmt.date(from: comment.createdAt) else { return "" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: comment.inReplyToID == nil ? "bubble.left" : "arrow.turn.down.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(comment.author).font(.callout.bold())
                Text(age).font(.caption).foregroundStyle(.secondary)
                if comment.resolved {
                    Label("Resolved", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if editing {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    TextEditor(text: $editText)
                        .font(Typography.body)
                        .frame(minHeight: 68)
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .strokeBorder(Palette.cardBorder)
                        }
                    HStack {
                        Spacer()
                        Button("Cancel") { editing = false }
                        Button("Save") { submitEdit() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || editText == comment.body)
                    }
                    .font(Typography.meta)
                }
            } else {
                MarkdownBodyView(text: comment.body)
            }

            HStack(spacing: 12) {
                Button(replying ? "Cancel" : "Reply") {
                    replying.toggle()
                    replyText = ""
                }
                .buttonStyle(.link)
                .font(.caption)
                if onEdit != nil, !editing {
                    Button("Edit") {
                        editText = comment.body
                        editing = true
                        replying = false
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if comment.inReplyToID == nil, comment.threadID != nil, !comment.resolved {
                    Button("Resolve") { onResolve() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if replying {
                HStack {
                    TextField("Reply…", text: $replyText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitReply() }
                    Button("Send") { submitReply() }
                        .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(comment.resolved ? 0.3 : 0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.cardBorder)
        }
        .opacity(comment.resolved ? 0.75 : 1)
        .padding(.vertical, 4)
        .padding(.leading, indented ? (comment.inReplyToID == nil ? 60 : 84)
                                    : (comment.inReplyToID == nil ? 0 : 22))
        .padding(.trailing, indented ? 16 : 0)
        .frame(maxWidth: indented ? 760 : .infinity, alignment: .leading)
    }

    private func submitEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onEdit?(text)
        editing = false
    }

    private func submitReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onReply(text)
        replying = false
        replyText = ""
    }

}

/// One run of changed rows, positioned as a fraction of the file.
struct ChangeBlock: Equatable {
    let rowID: Int
    let fraction: CGFloat
    let extent: CGFloat
    let color: Color

    static func kind(of row: SideBySideRow) -> LineKind? {
        let l = row.left?.kind, r = row.right?.kind
        if r == .addition || l == .addition { return .addition }
        if l == .deletion || r == .deletion { return .deletion }
        if l == nil || r == nil { return .addition }  // filler side of a change
        return nil
    }
}

/// IntelliJ-style change-overview rail: ticks mark where changes live in the
/// whole file; clicking one jumps the diff there.
struct ChangeRailView: View {
    let blocks: [ChangeBlock]
    /// Click a tick: jump to that block of changes.
    let onJump: (Int) -> Void
    /// Drag the rail: scrub to that fraction of the file, continuously.
    let onScrub: (CGFloat) -> Void

    /// Distinguishes a click from a drag. A click that has not moved snaps to
    /// the nearest tick; once it moves it becomes a free scrub, so the rail
    /// works like a scrollbar rather than only teleporting between changes.
    @State private var scrubbing = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Palette.surface
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(block.color.opacity(0.9))
                        .frame(width: 7, height: max(3, block.extent * geo.size.height))
                        .offset(x: 2.5, y: block.fraction * geo.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard scrubbing || abs(value.translation.height) > 2 else { return }
                        scrubbing = true
                        onScrub(ratio(value.location.y, in: geo.size.height))
                    }
                    .onEnded { value in
                        let r = ratio(value.location.y, in: geo.size.height)
                        if scrubbing {
                            onScrub(r)
                        } else if let nearest = blocks.min(by: {
                            abs($0.fraction + $0.extent / 2 - r) < abs($1.fraction + $1.extent / 2 - r)
                        }) {
                            onJump(nearest.rowID)
                        }
                        scrubbing = false
                    }
            )
        }
        .frame(width: DiffMetrics.railWidth)
        .accessibilityLabel("Change overview")
    }

    private func ratio(_ y: CGFloat, in height: CGFloat) -> CGFloat {
        min(max(y / max(height, 1), 0), 1)
    }
}

/// Holds row frames without publishing changes. See `rowFrames`.
private final class RowFrameStore: @unchecked Sendable {
    var frames: [Int: CGRect] = [:]
}

private struct RowFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Full-height strip over the center divider that drags the old/new column
/// balance. Uses absolute cursor position (not translation) so the divider
/// lands exactly under the pointer, and a high-priority gesture so the
/// ScrollView's pan can't swallow the drag.
private struct SplitHandle: View {
    @Binding var split: Double
    let paneWidth: CGFloat
    let dividerX: CGFloat
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Accent only while actively dragging: hover state can stick
                // when the exit event is lost (focus switches), which left a
                // bright blue line down the middle.
                Rectangle()
                    .fill(dragging ? Color.accentColor.opacity(0.5)
                          : hovering ? Color.primary.opacity(0.25) : Color.clear)
                    .frame(width: (hovering || dragging) ? 3 : 1)
            }
            .frame(width: 17, height: geo.size.height)
            .contentShape(Rectangle())
            .position(x: dividerX, y: geo.size.height / 2)
            .highPriorityGesture(
                // `.position` wraps the strip in a full-pane frame, so the
                // gesture's .local space IS the pane: location.x maps straight
                // to the desired split.
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        dragging = true
                        split = min(0.75, max(0.25, value.location.x / paneWidth))
                    }
                    .onEnded { _ in dragging = false }
            )
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
        }
        .allowsHitTesting(true)
    }
}

/// The lines a new comment will be attached to.
struct CommentTarget: Identifiable, Equatable {
    let startLine: Int
    let endLine: Int
    var id: String { "\(startLine)-\(endLine)" }
}

/// Composer for a new review thread on a line or range.
struct NewCommentSheet: View {
    let path: String
    let target: CommentTarget
    var onSend: (String) -> Void
    var onCancel: () -> Void
    @State private var body_ = ""

    /// "file.py:42" or "file.py:42-50", so it is unambiguous where this lands.
    private var targetLabel: String {
        let name = String(path.split(separator: "/").last ?? "")
        return target.startLine == target.endLine
            ? "\(name):\(target.startLine)"
            : "\(name):\(target.startLine)-\(target.endLine)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.secondary)
                Text("New comment").font(Typography.sectionTitle)
                Text(targetLabel)
                    .font(Typography.path)
                    .padding(.horizontal, Spacing.xs).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            TextEditor(text: $body_)
                .font(Typography.body)
                .frame(minHeight: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Palette.cardBorder)
                }
            HStack {
                // The most common failure is picking a line GitHub does not
                // consider part of the diff, so say where it will land.
                Text("Posts to GitHub on the PR's head commit.")
                    .font(Typography.meta).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Comment") { onSend(body_.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 520)
    }
}
