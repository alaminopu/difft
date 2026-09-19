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
    /// Review findings on this file, rendered under the line they name — the
    /// defect belongs on the code, not in a list you cross-reference by hand.
    public let findings: [Finding]
    public var onAsk: (String, String) -> Void  // (selectedText, contextChip)
    /// A keyboard command from the owner, consumed and cleared here.
    @Binding var command: DiffCommand?
    /// The change block `N`/`P` last landed on.
    @State private var changeCursor: Int?

    // Old/new column balance, draggable via the center divider. Persisted
    // globally (not per file) so it survives file switches and relaunches.
    @AppStorage("diffSplitFraction") private var split = 0.5
    @AppStorage(PrefKey.diffDensity) private var density = DiffDensity.comfortable

    fileprivate struct DiffItem: Identifiable, Sendable {
        enum Kind: Sendable {
            case hunkHeader(index: Int, text: String)
            case row(SideBySideRow)
            /// A whole conversation as one card: root and replies used to be
            /// separate items, which drew a reply as a second, indented box
            /// with its own Reply button.
            case thread(CommentThread)
            case finding(Finding)
            /// Stands in for a run of unchanged rows until the reader asks for
            /// them. `region` indexes `Built.hidden`.
            case collapsed(region: Int, lines: Int)
        }
        /// Assigned once while building.
        ///
        /// This was a computed `String` — `"r\(row.id)"` and friends — and
        /// `ForEach` materialises an id for every element to maintain identity,
        /// lazy rendering or not. On a full-context diff that is one heap
        /// allocation per line of the file on every structural update.
        let id: Int
        let kind: Kind
    }

    fileprivate struct Built: Sendable {
        var items: [DiffItem] = []
        /// Rows folded away, by region. Kept here rather than rebuilt so
        /// expanding a band is a splice, not another pass over the file.
        var hidden: [Int: [DiffItem]] = [:]
        /// Row id to the region hiding it, so focusing a line can open the
        /// band that contains it instead of scrolling to nothing.
        var regionOfRow: [Int: Int] = [:]
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
    /// A short explanation for an action that could not proceed, shown at the
    /// top of the diff and dismissed by the reader or the next file.
    @State private var notice: String?
    /// Bands the reader has opened.
    @State private var expandedRegions: Set<Int> = []
    /// `built.items` with the opened bands spliced back in.
    ///
    /// Held rather than computed: the splice is O(items), and a computed
    /// property would pay it on every body pass — which on a full-context diff
    /// is the whole file, on every scroll tick.
    @State private var shownItems: [DiffItem] = []

    public var onReplyComment: (ReviewComment, String) -> Void = { _, _ in }
    public var onResolveComment: (ReviewComment) -> Void = { _ in }
    /// nil for a comment that is not the signed-in user's.
    public var onEditComment: ((ReviewComment) -> ((String) -> Void)?)?
    /// (path, startLine, endLine, body). nil disables commenting entirely,
    /// which is what a single-commit diff wants — its line numbers are not
    /// the ones GitHub anchors PR comments to.
    public var onAddComment: ((Int, Int, String) -> Void)?
    /// Stage into the pending review rather than posting.
    public var onStageComment: ((Int, Int, String) -> Void)?
    /// Notes already staged, so the composer can say what this one joins.
    public var stagedCount: Int = 0
    /// nil where findings cannot be triaged, which hides the action.
    public var onDismissFinding: ((Finding) -> Void)?

    public init(file: FileDiff, layout: Binding<DiffLayout>, selection: Binding<LineSelection?>,
                fontSize: Int = DiffMetrics.defaultFontSize, focusLine: Int? = nil,
                comments: [ReviewComment] = [], findings: [Finding] = [],
                command: Binding<DiffCommand?> = .constant(nil),
                onFocused: @escaping () -> Void = {}, onAsk: @escaping (String, String) -> Void,
                onReplyComment: @escaping (ReviewComment, String) -> Void = { _, _ in },
                onResolveComment: @escaping (ReviewComment) -> Void = { _ in },
                onEditComment: ((ReviewComment) -> ((String) -> Void)?)? = nil,
                onAddComment: ((Int, Int, String) -> Void)? = nil,
                onStageComment: ((Int, Int, String) -> Void)? = nil,
                onDismissFinding: ((Finding) -> Void)? = nil,
                stagedCount: Int = 0) {
        self._command = command
        self.onDismissFinding = onDismissFinding
        self.onReplyComment = onReplyComment
        self.onResolveComment = onResolveComment
        self.onEditComment = onEditComment
        self.onAddComment = onAddComment
        self.onStageComment = onStageComment
        self.stagedCount = stagedCount
        self.file = file; self._layout = layout; self._selection = selection
        self.fontSize = fontSize; self.focusLine = focusLine
        self.onFocused = onFocused; self.onAsk = onAsk
        self.comments = comments; self.findings = findings
    }


    nonisolated fileprivate static func build(file: FileDiff, sideBySide: Bool,
                                  comments: [ReviewComment], findings: [Finding],
                                  key: String) -> Built {
        var items: [DiffItem] = []
        var rows: [SideBySideRow] = []
        var base = 0
        // A full-context diff is one hunk spanning the whole file; its @@
        // header is noise there.
        let fullFile = file.hunks.count == 1
            && (file.hunks[0].lines.first.flatMap { $0.oldNumber ?? $0.newNumber } ?? 0) <= 1
        var uid = 0
        func next() -> Int { defer { uid += 1 }; return uid }

        for (i, hunk) in file.hunks.enumerated() {
            if !fullFile, !hunk.header.isEmpty {
                items.append(DiffItem(id: next(), kind: .hunkHeader(index: i, text: hunk.header)))
            }
            let local = sideBySide ? RowPairer.rows(for: [hunk]) : RowPairer.unifiedRows(for: [hunk])
            for r in local {
                // `counterpart` has to survive the id remap: without it
                // `emphasisPair` always returned nil and word-level emphasis
                // silently never rendered in unified layout.
                let remapped = SideBySideRow(id: base + r.id, left: r.left, right: r.right,
                                             counterpart: r.counterpart)
                items.append(DiffItem(id: next(), kind: .row(remapped)))
                rows.append(remapped)
            }
            base += local.count
        }

        // Line-number indexes, built once.
        //
        // Anchoring used to scan every row for each comment and then every
        // item for that row's id — allocating a String per item it compared —
        // and then shift the array to insert. Twenty comments on a ten-thousand
        // line file was a few hundred thousand allocations before the diff
        // could appear.
        var rowByNewLine: [Int: Int] = [:]      // line -> row id
        var rowByOldLine: [Int: Int] = [:]      // line -> row id, either side
        var rowByLeftOldLine: [Int: Int] = [:]  // line -> row id, old side only
        for r in rows {
            if let n = r.right?.newNumber { rowByNewLine[n] = rowByNewLine[n] ?? r.id }
            if let n = r.left?.newNumber { rowByNewLine[n] = rowByNewLine[n] ?? r.id }
            if let o = r.left?.oldNumber {
                rowByOldLine[o] = rowByOldLine[o] ?? r.id
                rowByLeftOldLine[o] = rowByLeftOldLine[o] ?? r.id
            }
            if let o = r.right?.oldNumber { rowByOldLine[o] = rowByOldLine[o] ?? r.id }
        }

        // Findings first, then comments: a defect outranks a conversation.
        var attachments: [Int: [DiffItem]] = [:]
        for finding in findings {
            guard let rowID = rowByNewLine[finding.line] ?? rowByLeftOldLine[finding.line]
            else { continue }
            attachments[rowID, default: []].append(DiffItem(id: next(), kind: .finding(finding)))
        }
        // LEFT comments match old line numbers, RIGHT (the default) match new
        // ones. Outdated comments with no line are skipped.
        for thread in CommentThread.group(comments) {
            guard let line = thread.root.line else { continue }
            guard let rowID = (thread.root.side == "LEFT" ? rowByOldLine[line] : rowByNewLine[line])
            else { continue }
            attachments[rowID, default: []].append(DiffItem(id: next(), kind: .thread(thread)))
        }
        if !attachments.isEmpty {
            var merged: [DiffItem] = []
            merged.reserveCapacity(items.count + attachments.values.reduce(0) { $0 + $1.count })
            for item in items {
                merged.append(item)
                if case .row(let r) = item.kind, let extra = attachments[r.id] {
                    merged.append(contentsOf: extra)
                }
            }
            items = merged
        }
        // Fold the long unchanged runs away. Rows carrying a comment or a
        // finding are pinned: they are the reason the reader opened the file.
        let regions = CollapsedRegions.compute(rows: rows, pinned: Set(attachments.keys))
        var hidden: [Int: [DiffItem]] = [:]
        var regionOfRow: [Int: Int] = [:]
        if !regions.isEmpty {
            var linesIn: [Int: Int] = [:]
            for region in regions {
                linesIn[region.id] = region.count
                for index in region.range { regionOfRow[rows[index].id] = region.id }
            }
            var folded: [DiffItem] = []
            folded.reserveCapacity(items.count)
            var banded = Set<Int>()
            for item in items {
                guard case .row(let r) = item.kind, let region = regionOfRow[r.id] else {
                    folded.append(item)
                    continue
                }
                hidden[region, default: []].append(item)
                if banded.insert(region).inserted {
                    folded.append(DiffItem(id: next(),
                                           kind: .collapsed(region: region,
                                                            lines: linesIn[region] ?? 0)))
                }
            }
            items = folded
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
            let color: Color = (hasAdd && hasDel) ? Palette.mixed
                : hasDel ? Palette.removed : Palette.added
            blocks.append(ChangeBlock(rowID: rows[start].id,
                                      fraction: CGFloat(start) / total,
                                      extent: CGFloat(i - start) / total,
                                      color: color))
        }
        return Built(items: items, hidden: hidden, regionOfRow: regionOfRow,
                     allRows: rows, changeBlocks: blocks,
                     digits: DiffMetrics.digits(for: file.maxLineNumber), key: key)
    }

    /// Keyed on comment identity and state, not just count: resolving a
    /// comment changes `resolved` without changing the count, and the stale
    /// card used to stay on screen.
    private var buildKey: String {
        let commentKey = comments.map { "\($0.id):\($0.resolved)" }.joined(separator: ",")
        let findingKey = findings.map { "\($0.id):\($0.dismissed)" }.joined(separator: ",")
        return "\(file.path)|\(layout)|\(commentKey)|\(findingKey)"
    }

    /// Diff geometry for this file: the gutter is sized from the widest line
    /// number it actually has to show, at the current font size.
    private var metrics: DiffMetrics {
        DiffMetrics(fontSize: CGFloat(fontSize),
                    digits: built.digits,
                    unified: layout == .unified,
                    density: density)
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
                            ForEach(shownItems) { item in
                                switch item.kind {
                                case .collapsed(let region, let lines):
                                    CollapsedBandView(lines: lines, metrics: metrics) {
                                        expandedRegions.insert(region)
                                    }
                                case .hunkHeader(_, let text):
                                    HunkHeaderView(text: text, metrics: metrics)
                                case .finding(let f):
                                    InlineFindingView(finding: f, sideBySide: layout == .sideBySide,
                                                      onDismiss: onDismissFinding.map { dismiss in { dismiss(f) } })
                                case .thread(let thread):
                                    ThreadCardView(thread: thread,
                                                   onReply: { body in onReplyComment(thread.root, body) },
                                                   onResolve: { onResolveComment(thread.root) },
                                                   onEdit: { onEditComment?($0) })
                                        .padding(.vertical, Spacing.sm)
                                        .padding(.trailing, Spacing.xl)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
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
                                                    ? nil : { id in startComment(rowID: id) },
                                                onContextCopyReference: { id in copyReference(rowID: id) })
                                        // Scroll targets address rows by id;
                                        // only rendered rows pay for it.
                                        .id("r\(row.id)")
                                        .background(GeometryReader { rowGeo in
                                            // Recorded straight into a plain
                                            // (non-observable) store rather than
                                            // through a PreferenceKey: the key
                                            // allocated a one-entry dictionary
                                            // per visible row and merged them
                                            // on every scroll tick, and the
                                            // frames are read only by the drag
                                            // gesture's hit test.
                                            rowFrames.record(
                                                row.id, rowGeo.frame(in: .named("diffSpace")))
                                            return Color.clear
                                        })
                                }
                            }
                        }
                        .frame(width: contentW, alignment: .leading)
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
                        // Another file, or another layout: the recorded row
                        // frames describe rows that no longer exist, and the
                        // bands the reader opened were in the previous file.
                        rowFrames.reset()
                        notice = nil
                        expandedRegions = []
                        shownItems = built.items
                        guard !built.allRows.isEmpty else { return }
                        if focusLine != nil {
                            focusIfNeeded(proxy)
                        } else {
                            scrollToFirstChange(proxy)
                        }
                    }
                    .onChange(of: focusLine) { focusIfNeeded(proxy) }
                    .onChange(of: command) { _, new in
                        guard let new else { return }
                        command = nil
                        run(new, proxy)
                    }
                    .onChange(of: expandedRegions) { _, _ in respliceItems() }
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
                NewCommentSheet(
                    path: file.path, target: target,
                    onStage: { body in
                        onStageComment?(target.startLine, target.endLine, body)
                        composing = nil
                    },
                    onSend: { body in
                        onAddComment?(target.startLine, target.endLine, body)
                        composing = nil
                    },
                    onCancel: { composing = nil },
                    stagedCount: stagedCount)
            }
            .task(id: buildKey) {
                // Off the main actor: a big file builds in background and pops
                // in; body evaluations stay cheap in the meantime.
                let f = file, side = layout == .sideBySide, cs = comments, fs = findings, key = buildKey
                guard built.key != key else { return }
                built = await Task.detached(priority: .userInitiated) {
                    Self.build(file: f, sideBySide: side, comments: cs, findings: fs, key: key)
                }.value
                if focusLine != nil { /* focus re-applied by focusIfNeeded below via onAppear path */ }
            }
            .overlay {
                if built.key.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if file.isGenerated { GeneratedFileBanner() }
                    if let notice { NoticeBanner(text: notice) { self.notice = nil } }
                }
            }
        }
    }

    private func run(_ command: DiffCommand, _ proxy: ScrollViewProxy) {
        switch command.kind {
        case .nextChange, .previousChange:
            let blocks = built.changeBlocks
            guard !blocks.isEmpty else { return }
            let step = command.kind == .nextChange ? 1 : -1
            // First press lands on the first change, or the last going back.
            let next = changeCursor.map { min(blocks.count - 1, max(0, $0 + step)) }
                ?? (step > 0 ? 0 : blocks.count - 1)
            changeCursor = next
            let rowID = blocks[next].rowID
            if let region = built.regionOfRow[rowID], !expandedRegions.contains(region) {
                expandedRegions.insert(region)
                respliceItems()
            }
            selection = LineSelection(anchor: rowID, head: rowID)
            proxy.scrollTo("r\(rowID)", anchor: UnitPoint(x: 0, y: 0.3))
        case .comment:
            guard onAddComment != nil, let row = selection?.range.lowerBound else {
                notice = "Select the lines to comment on first."
                return
            }
            startComment(rowID: row)
        case .ask:
            guard let row = selection?.range.lowerBound else {
                notice = "Select the lines to ask about first."
                return
            }
            askAbout(rowID: row)
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
        guard let low = newLines.min(), let high = newLines.max() else {
            // Silently doing nothing read as a broken menu item. Say why: the
            // selection is entirely lines that no longer exist.
            notice = "GitHub anchors a comment to a line of the new file. "
                + "This selection is only deleted lines."
            return
        }
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

    /// "src/form/main.py:105-106", the form every tracker and chat links.
    private func copyReference(rowID: Int) {
        let sel = effectiveSelection(for: rowID)
        let lines = built.allRows.filter { sel.range.contains($0.id) }
            .compactMap { ($0.right ?? $0.left)?.newNumber ?? ($0.left ?? $0.right)?.oldNumber }
        guard let low = lines.min(), let high = lines.max() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(low == high ? "\(file.path):\(low)" : "\(file.path):\(low)-\(high)",
                                       forType: .string)
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
        // An unchanged line named by a finding or a walkthrough anchor may be
        // folded away; scrolling to a row that is not rendered does nothing at
        // all, so open its band first.
        if let region = built.regionOfRow[row.id], !expandedRegions.contains(region) {
            expandedRegions.insert(region)
            respliceItems()
        }
        // Unanimated, and a tick later. Animating a jump across a lazy list
        // realises every row in between and then gives up, leaving the view at
        // the first change instead of the line asked for; and the rows opened
        // above are not in the hierarchy until the next update.
        let target = "r\(row.id)"
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
        onFocused()
    }

    /// Puts the opened bands' rows back in place.
    private func respliceItems() {
        guard !expandedRegions.isEmpty else {
            shownItems = built.items
            return
        }
        var result: [DiffItem] = []
        result.reserveCapacity(built.items.count)
        for item in built.items {
            guard case .collapsed(let region, _) = item.kind,
                  expandedRegions.contains(region) else {
                result.append(item)
                continue
            }
            result.append(contentsOf: built.hidden[region] ?? [])
        }
        shownItems = result
    }
}

/// Stands in for a run of unchanged lines.
///
/// A full-context diff puts the whole file on screen, and on a typical commit
/// around 95% of it is untouched. This keeps every line one click away while
/// letting the changes be the thing you actually see.
struct CollapsedBandView: View {
    let lines: Int
    let metrics: DiffMetrics
    let expand: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: expand) {
            HStack(spacing: Spacing.sm + 2) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .frame(width: metrics.totalGutter - Spacing.sm, alignment: .trailing)
                Text("\(lines) unchanged line\(lines == 1 ? "" : "s")")
                    .font(Typography.meta)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.text : Palette.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(hovering ? Palette.surfaceRaised : Palette.band)
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.vertical, Spacing.xs)
        .help("Show these lines")
        .accessibilityLabel("Show \(lines) unchanged lines")
    }
}

/// Markdown-ish body shared by chat messages and comment cards: prose with
/// inline markdown, fenced code blocks monospaced and syntax-highlighted
/// (language auto-detected).


/// NSCache needs a class; AttributedString is a value type.
private final class InlineRun {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

/// One line of explanation for something the app declined to do.
///
/// An action that quietly does nothing reads as a bug. This is the cheapest
/// honest alternative: say what happened, and get out of the way.
struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "info.circle").imageScale(.small)
            Text(text)
            Spacer(minLength: 0)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .font(Typography.meta)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.band)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

/// Says a file is machine-written, so a reader can skip it deliberately
/// rather than wonder why 4,000 lines changed.
///
/// The diff is shown regardless. Files the repository excludes from diffs
/// entirely (`-diff` in `.gitattributes`) used to reach this view as an
/// unviewable "Binary file"; they are re-read as text upstream, and this is
/// what says where the content came from.
struct GeneratedFileBanner: View {
    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "gearshape.2").imageScale(.small)
            Text("Generated file — marked in .gitattributes")
            Spacer(minLength: 0)
        }
        .font(Typography.meta)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.band)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }
}

public struct MarkdownBodyView: View {
    public let text: String
    @EnvironmentObject var highlighter: HighlightService
    @AppStorage(PrefKey.codeFontFamily) private var codeFontFamily = CodeFont.systemFamily
    @Environment(\.repoSlug) private var repoSlug

    public init(text: String) { self.text = text }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(CommentBodySegment.parse(CommentHTML.markdown(from: text)).enumerated()),
                    id: \.offset) { _, seg in
                switch seg {
                case .text(let t):
                    // Split out markdown heading lines (inline-only parsing
                    // would show the ### literally).
                    ForEach(Array(Self.headingChunks(t).enumerated()), id: \.offset) { _, chunk in
                        if chunk.isHeading {
                            Text(chunk.text)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.textStrong)
                                .padding(.top, Spacing.xs)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(Self.inline(chunk.text, codeFamily: codeFontFamily, repoSlug: repoSlug))
                                .font(Typography.body)
                                .foregroundStyle(Palette.text)
                                .lineSpacing(Typography.bodyLineSpacing)
                                .tint(Palette.accent)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .code(let c):
                    ScrollView(.horizontal) {
                        Text(highlighter.highlightedAuto(c))
                            .textSelection(.enabled)
                            .padding(Spacing.sm + 2)
                    }
                    .background(Palette.canvas, in: RoundedRectangle(cornerRadius: Radius.md))
                    .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Palette.hairline) }
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
        // Every comment card, every chat message and the PR description all
        // re-parse markdown from scratch inside `body`, and any change to the
        // highlighter re-renders all of them at once. The parse does not
        // depend on anything but these three values.
        let key = "\(codeFamily)\u{1}\(repoSlug ?? "")\u{1}\(markdown)" as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let built = buildInline(markdown, codeFamily: codeFamily, repoSlug: repoSlug)
        inlineCache.setObject(InlineRun(built), forKey: key)
        return built
    }

    private static let inlineCache: NSCache<NSString, InlineRun> = {
        let c = NSCache<NSString, InlineRun>()
        c.countLimit = 600
        return c
    }()

    private static func buildInline(_ markdown: String, codeFamily: String,
                                    repoSlug: String?) -> AttributedString {
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
        let ranges = CommitReference.ranges(in: plain)
        guard !ranges.isEmpty else { return }
        // Materialised once. Indexing it per match rebuilt the whole body as a
        // [Character] array for every SHA mentioned.
        let characters = Array(plain)

        // Applying links shifts nothing, but walking back to front keeps the
        // offsets valid regardless of how attribute runs get split.
        for range in ranges.reversed() {
            guard let lo = attr.index(attr.startIndex, offsetByCharacters: range.lowerBound)
                    as AttributedString.Index?,
                  let hi = attr.index(attr.startIndex, offsetByCharacters: range.upperBound)
                    as AttributedString.Index? else { continue }
            let slice = attr[lo..<hi]
            if slice.runs.contains(where: {
                $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true
            }) { continue }

            let sha = String(characters[range])
            guard let url = CommitReference.url(sha: sha) else { continue }
            attr[lo..<hi].link = url
            attr[lo..<hi].font = CodeFont.swiftUIFont(family: codeFamily, size: 12)
        }
    }

    struct Chunk { let text: String; let isHeading: Bool }

    /// The text after a leading `#`…`######` and at least one space, or nil.
    ///
    /// Was `range(of:options:.regularExpression)`, which compiles an
    /// NSRegularExpression per line of every comment body, on every render.
    static func headingText(_ trimmed: String) -> String? {
        var hashes = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#", hashes < 6 {
            hashes += 1
            index = trimmed.index(after: index)
        }
        guard hashes > 0, index < trimmed.endIndex, trimmed[index] == " " else { return nil }
        while index < trimmed.endIndex, trimmed[index] == " " { index = trimmed.index(after: index) }
        return String(trimmed[index...])
    }
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
            if let heading = Self.headingText(trimmed) {
                flush()
                chunks.append(Chunk(text: heading, isHeading: true))
            } else {
                para.append(Self.listMarker(line))
            }
        }
        flush()
        return chunks
    }

    /// Bullets and task boxes for list lines. Inline-only markdown parsing
    /// leaves "- [ ] Bug fix" exactly as typed, and a PR template's checklist
    /// read as a column of punctuation.
    static func listMarker(_ line: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        guard rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") else { return line }
        let item = rest.dropFirst(2)
        let lowered = item.prefix(4).lowercased()
        if lowered.hasPrefix("[ ] ") { return indent + "\u{2610}  " + item.dropFirst(4) }
        if lowered.hasPrefix("[x] ") { return indent + "\u{2611}  " + item.dropFirst(4) }
        return indent + "\u{2022}  " + item
    }
}

/// One comment: who, when, what they said. No box of its own — the thread
/// card (in the diff) or the thread list (in the Threads pane) supplies that,
/// so a conversation reads as one thing rather than a stack of cards.
public struct CommentCardView: View {
    let comment: ReviewComment
    var onReply: (String) -> Void = { _ in }
    var onResolve: () -> Void = {}
    /// nil when the comment is not the signed-in user's, which is what hides
    /// the Edit action rather than showing one that would fail.
    var onEdit: ((String) -> Void)?
    /// Kept for source compatibility; the thread card owns layout now.
    var indented: Bool = true
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

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm + 2) {
            AvatarDisc(login: comment.author)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(comment.author)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.textStrong)
                    Text(Dates.age(iso: comment.createdAt))
                        .font(Typography.meta).foregroundStyle(Palette.textTertiary)
                    Spacer(minLength: 0)
                    if onEdit != nil, !editing {
                        Button("Edit") {
                            editText = comment.body
                            editing = true
                        }
                        .buttonStyle(QuietButtonStyle(tint: Palette.textSecondary))
                    }
                }
                if editing {
                    VStack(alignment: .trailing, spacing: Spacing.sm) {
                        ComposerEditor(text: $editText, minHeight: 68)
                        HStack(spacing: Spacing.sm) {
                            Button("Cancel") { editing = false }
                                .buttonStyle(SecondaryButtonStyle())
                            Button("Save") { submitEdit() }
                                .buttonStyle(PrimaryButtonStyle())
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          || editText == comment.body)
                        }
                    }
                } else {
                    MarkdownBodyView(text: comment.body)
                }
            }
        }
        .contextMenu {
            Button("Copy Comment") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(comment.body, forType: .string)
            }
            Button("Copy as Quote") {
                let quoted = comment.body.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(quoted, forType: .string)
            }
            if onEdit != nil {
                Divider()
                Button("Edit") { editText = comment.body; editing = true }
            }
        }
    }

    private func submitEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onEdit?(text)
        editing = false
    }
}

/// A bordered multi-line editor in the app's own surfaces.
public struct ComposerEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120

    public init(text: Binding<String>, minHeight: CGFloat = 120) {
        self._text = text
        self.minHeight = minHeight
    }

    public var body: some View {
        TextEditor(text: $text)
            .font(Typography.body)
            .lineSpacing(Typography.bodyLineSpacing)
            .scrollContentBackground(.hidden)
            .padding(Spacing.sm)
            .frame(minHeight: minHeight)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Palette.cardBorder) }
    }
}

/// A review conversation, anchored under its line: every comment in one card,
/// one reply field, one Resolve.
public struct ThreadCardView: View {
    let thread: CommentThread
    var onReply: (String) -> Void
    var onResolve: () -> Void
    /// The edit handler for a given comment, or nil when it is not the user's.
    var onEdit: (ReviewComment) -> ((String) -> Void)?
    /// Fills its container (the Threads pane) rather than sitting at reading
    /// width under a line of code.
    var fillsWidth = false
    @State private var replyText = ""
    @State private var expandedResolved = false
    @FocusState private var replying: Bool

    public init(thread: CommentThread,
                onReply: @escaping (String) -> Void,
                onResolve: @escaping () -> Void,
                onEdit: @escaping (ReviewComment) -> ((String) -> Void)? = { _ in nil },
                fillsWidth: Bool = false) {
        self.thread = thread
        self.onReply = onReply
        self.onResolve = onResolve
        self.onEdit = onEdit
        self.fillsWidth = fillsWidth
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if thread.resolved && !expandedResolved {
                resolvedSummary
            } else {
                ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                    if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    CommentCardView(comment: comment, onEdit: onEdit(comment))
                        .padding(.horizontal, Spacing.md + 2)
                        .padding(.vertical, Spacing.md)
                }
                footer
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : 560, alignment: .leading)
        .card(border: thread.resolved ? Palette.cardBorder : Palette.amber.opacity(0.45))
        .opacity(thread.resolved ? 0.8 : 1)
    }

    /// A settled conversation folds to a line: it is history, and leaving it
    /// open pushed the code it was about off the screen.
    private var resolvedSummary: some View {
        Button { expandedResolved = true } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.added)
                Text("Resolved").fontWeight(.medium).foregroundStyle(Palette.text)
                Text("\(thread.participants.joined(separator: ", ")) \u{00B7} \(thread.comments.count) comment\(thread.comments.count == 1 ? "" : "s")")
                    .foregroundStyle(Palette.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .font(Typography.control)
            .padding(.horizontal, Spacing.md + 2)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the resolved conversation")
    }

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            TextField("Reply\u{2026}", text: $replyText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .lineLimit(1...6)
                .focused($replying)
                .onSubmit { submitReply() }
                .padding(.horizontal, Spacing.sm + 2)
                .padding(.vertical, 6)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.cardBorder) }
            if !replyText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Send") { submitReply() }.buttonStyle(PrimaryButtonStyle())
            } else if thread.root.threadID != nil, !thread.resolved {
                Button("Resolve") { onResolve() }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, Spacing.md + 2)
        .padding(.vertical, Spacing.sm + 2)
        .background(Palette.chrome.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private func submitReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onReply(text)
        replyText = ""
        replying = false
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
                Palette.band
                Rectangle().fill(Palette.hairline).frame(width: 1)
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(block.color)
                        .frame(width: 6, height: max(4, block.extent * geo.size.height))
                        .offset(x: 3.5, y: block.fraction * geo.size.height)
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

/// A review finding on the line it names.
///
/// Deliberately quieter than a comment card: it is annotation on the code, not
/// a conversation, and a full-width panel per finding would bury the diff it
/// is about.
struct InlineFindingView: View {
    let finding: Finding
    /// In a split diff the note sits under the new side, where its line is.
    var sideBySide = false
    var onDismiss: (() -> Void)?
    @State private var expanded = false

    private var tint: Color {
        switch finding.severity.lowercased() {
        case "high": return Palette.removedText
        case "medium": return Palette.amber
        default: return Palette.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(tint)
                Text(finding.severity.uppercased())
                    .font(.system(size: 10.5, weight: .bold)).kerning(0.5).foregroundStyle(tint)
                // One line until opened: an unclamped explanation ran seven
                // lines and shoved the code it annotates off the screen.
                Text(finding.explanation)
                    .font(Typography.control)
                    .foregroundStyle(finding.dismissed ? Palette.textTertiary : Palette.text)
                    .strikethrough(finding.dismissed)
                    .lineLimit(expanded ? nil : 1)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: expanded)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .foregroundStyle(Palette.textTertiary)
            }
            if expanded {
                if !finding.failureScenario.isEmpty {
                    Text(finding.failureScenario)
                        .font(Typography.control).foregroundStyle(Palette.textSecondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Spacing.xl - 2)
                }
                if let onDismiss, !finding.dismissed {
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(QuietButtonStyle(tint: Palette.textSecondary))
                        .padding(.leading, Spacing.xl - 2)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm - 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .overlay(alignment: .top) { Rectangle().fill(tint.opacity(0.28)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.28)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() } }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Finding") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "[\(finding.severity)] \(finding.file):\(finding.line)\n\(finding.explanation)"
                    + (finding.failureScenario.isEmpty ? "" : "\n\(finding.failureScenario)"),
                    forType: .string)
            }
            if let onDismiss, !finding.dismissed { Button("Dismiss Finding", action: onDismiss) }
        }
    }
}

/// Holds row frames without publishing changes. See `rowFrames`.
///
/// Deliberately not observable: these are written during layout, for every
/// visible row, on every scroll tick. Anything that invalidated a view here
/// would loop.
private final class RowFrameStore: @unchecked Sendable {
    private(set) var frames: [Int: CGRect] = [:]

    func record(_ id: Int, _ frame: CGRect) { frames[id] = frame }

    /// Frames are in the scroll content's coordinate space, so they stay
    /// correct as rows scroll away — but they belong to one file in one
    /// layout, and must go when either changes.
    func reset() { frames.removeAll(keepingCapacity: true) }
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
    /// Mirrors what this view has actually pushed onto `NSCursor`'s global
    /// stack, so every push is matched by exactly one pop. See `setCursor`.
    @State private var pushedCursor = false

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
            // Hover is tracked on the 17pt strip itself, BEFORE `.position`
            // wraps it in a full-pane frame — attached after, it tracks that
            // pane and the resize cursor appears across the whole diff.
            .onHover { inside in setCursor(inside) }
            .onDisappear {
                // Switching to Unified, or to another file, removes this view
                // while the pointer is still over it, so the exit event never
                // arrives. Without this the pushed cursor sticks for the rest
                // of the session and every view shows the resize arrows.
                setCursor(false)
            }
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
        }
    }

    /// `NSCursor.push()`/`pop()` drive a global stack, so an unmatched push
    /// changes the cursor everywhere until the app quits. SwiftUI re-sends
    /// hover on layout and focus changes, so guard on our own state rather
    /// than trusting the events to alternate.
    private func setCursor(_ inside: Bool) {
        guard inside != pushedCursor else { return }
        pushedCursor = inside
        hovering = inside
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
}

/// The lines a new comment will be attached to.
struct CommentTarget: Identifiable, Equatable {
    let startLine: Int
    let endLine: Int
    var id: String { "\(startLine)-\(endLine)" }
}

/// A keyboard command for the diff, sent down from whoever owns the keys.
///
/// Each one carries its own identity so pressing N twice is two changes of
/// value, not one.
public struct DiffCommand: Equatable {
    public enum Kind: Sendable { case nextChange, previousChange, comment, ask }
    public let kind: Kind
    private let id = UUID()
    public init(_ kind: Kind) { self.kind = kind }
}

/// Composer for a new review thread on a line or range.
struct NewCommentSheet: View {
    let path: String
    let target: CommentTarget
    /// Staged into the pending review.
    var onStage: (String) -> Void
    /// Posted on its own, the way a one-line "typo here" should be.
    var onSend: (String) -> Void
    var onCancel: () -> Void
    /// How many notes are already waiting, so the primary action can say what
    /// it is joining.
    var stagedCount: Int = 0
    @State private var body_ = ""

    private var trimmed: String { body_.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// "file.py:42" or "file.py:42-50", so it is unambiguous where this lands.
    private var targetLabel: String {
        let name = String(path.split(separator: "/").last ?? "")
        return target.startLine == target.endLine
            ? "\(name):\(target.startLine)"
            : "\(name):\(target.startLine)-\(target.endLine)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Text("New comment").font(Typography.sectionTitle)
                    .foregroundStyle(Palette.textStrong)
                Text(targetLabel)
                    .font(Typography.identifier).foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 5))
                Spacer()
            }
            ComposerEditor(text: $body_, minHeight: 130)
            HStack(spacing: Spacing.sm) {
                // The most common failure is picking a line GitHub does not
                // consider part of the diff, so say where it will land.
                Text("Anchors to the PR\u{2019}s head commit. Markdown works.")
                    .font(Typography.meta).foregroundStyle(Palette.textTertiary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                // Posting on its own is still right for a one-line "typo
                // here"; everything else belongs in the review.
                Button("Post now") { onSend(trimmed) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(trimmed.isEmpty)
                Button(stagedCount == 0 ? "Add to review" : "Add to review (\(stagedCount + 1))") {
                    onStage(trimmed)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 540)
        .background(Palette.floating)
    }
}
