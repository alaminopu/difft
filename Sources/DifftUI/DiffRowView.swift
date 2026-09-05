import SwiftUI
import DifftCore

struct HalfLineView: View {
    let line: DiffLine?
    let side: GutterSide
    let language: String?
    let intraline: [Range<Int>]
    let metrics: DiffMetrics
    var codeWidth: CGFloat? = nil
    /// IntelliJ-style center gutter: the LEFT half puts its numbers on its
    /// trailing edge so both number columns meet at the divider.
    var numbersTrailing: Bool = false
    var onGutterTap: (() -> Void)? = nil
    @EnvironmentObject var highlighter: HighlightService
    @Environment(\.colorScheme) private var colorScheme

    /// Diff washes need different alphas per scheme: the same alpha over white
    /// and over near-black does not read at the same strength.
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if numbersTrailing {
                code
                separator
                tappableGutter
            } else {
                tappableGutter
                separator
                code
            }
        }
        .background(background)
    }

    private var tappableGutter: some View {
        gutter
            .background(gutterBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                onGutterTap?()
            }
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: metrics.separatorWidth)
    }

    // Long lines wrap within the half's width instead of truncating
    // or requiring a horizontal pan.
    private var code: some View {
        // The font rides on the AttributedString itself — Highlightr stamps
        // it there, and that beats any .font modifier applied here.
        Text(attributed)
            .padding(.leading, metrics.codeInset)
            .padding(.vertical, metrics.rowPadding)
            .frame(width: codeWidth, alignment: .topLeading)
            .frame(maxWidth: codeWidth == nil ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Side-by-side halves show one number column; unified shows BOTH old and
    /// new columns (a single interleaved column reads as broken numbering).
    @ViewBuilder private var gutter: some View {
        let numberFont = Font.system(size: metrics.numberFontSize, design: .monospaced)
        if side == .unified {
            // One pre-formatted text: old and new numbers as fixed-width
            // fields, so both columns always align without nested layout.
            let text = Self.unifiedGutterText(old: line?.oldNumber, new: line?.newNumber)
            Text(text)
                .font(numberFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: metrics.gutterWidth, alignment: .trailing)
                .padding(.trailing, metrics.gutterTrailing)
                .padding(.top, metrics.rowPadding)
                .frame(maxHeight: .infinity, alignment: .topTrailing)
        } else {
            Text(line.flatMap { $0.gutterNumber(for: side) }.map(String.init) ?? "")
                .font(numberFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: metrics.gutterWidth, alignment: .trailing)
                .padding(.trailing, metrics.gutterTrailing)
                .padding(.top, metrics.rowPadding)
                .frame(maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    static func unifiedGutterText(old: Int?, new: Int?) -> String {
        func pad(_ n: Int?) -> String {
            let s = n.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, 5 - s.count)) + s
        }
        return pad(old) + " " + pad(new)
    }

    private var attributed: AttributedString {
        guard let line else { return AttributedString("") }
        var attr = highlighter.highlighted(line.text, language: language)
        // Overlay intraline emphasis. Bound against attr's own character count
        // (not line.text's) since Highlightr's output is not guaranteed to
        // preserve character count, and index(_:offsetByCharacters:) traps
        // on an out-of-bounds offset.
        let attrCount = attr.characters.count
        for range in intraline where range.upperBound <= attrCount {
            if let lo = attr.index(attr.startIndex, offsetByCharacters: range.lowerBound) as AttributedString.Index?,
               let hi = attr.index(attr.startIndex, offsetByCharacters: range.upperBound) as AttributedString.Index? {
                attr[lo..<hi].backgroundColor = line.kind == .addition
                    ? Palette.diffAddEmphasis(dark) : Palette.diffRemoveEmphasis(dark)
                // Dim syntax colours — comments especially — vanish against
                // the emphasis wash, so emphasised spans read at full
                // contrast. Dropping this in favour of weight alone made
                // commented-out code unreadable where it was emphasised.
                attr[lo..<hi].foregroundColor = Color.primary
                attr[lo..<hi].font = highlighter.emphasisFont
            }
        }
        return attr
    }

    private var background: Color {
        switch line?.kind {
        case .addition: Palette.diffAddFill(dark)
        case .deletion: Palette.diffRemoveFill(dark)
        case .context: Color.clear
        case nil: Palette.diffFiller(dark)  // filler: deliberately dimmed, not a hole
        }
    }

    private var gutterBackground: Color {
        switch line?.kind {
        case .addition: Palette.diffAddGutter(dark)
        case .deletion: Palette.diffRemoveGutter(dark)
        case .context: Palette.diffContextGutter(dark)
        case nil: Palette.diffFiller(dark)
        }
    }
}

struct DiffRowView: View {
    let row: SideBySideRow
    let layout: DiffLayout
    let language: String?
    let isSelected: Bool
    let metrics: DiffMetrics
    var leftCodeWidth: CGFloat? = nil
    var rightCodeWidth: CGFloat? = nil
    let onGutterClick: (Int, Bool) -> Void  // (rowID, shiftHeld)
    var onContextAsk: ((Int) -> Void)? = nil
    var onContextCopy: ((Int) -> Void)? = nil

    var body: some View {
        let ranges = intralineRanges
        Group {
            switch layout {
            case .sideBySide:
                HStack(alignment: .top, spacing: 0) {
                    HalfLineView(line: row.left, side: .left, language: language, intraline: ranges.old,
                                 metrics: metrics, codeWidth: leftCodeWidth,
                                 numbersTrailing: true, onGutterTap: select)
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(width: metrics.dividerWidth)
                    HalfLineView(line: row.right, side: .right, language: language, intraline: ranges.new,
                                 metrics: metrics, codeWidth: rightCodeWidth, onGutterTap: select)
                }
                .fixedSize(horizontal: false, vertical: true)
            case .unified:
                HalfLineView(line: row.left?.kind == .deletion ? row.left : row.right,
                             side: .unified,
                             language: language,
                             intraline: row.left?.kind == .deletion ? ranges.old : ranges.new,
                             metrics: metrics, onGutterTap: select)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The whole row is a selection target — gutter-only tapping was too
        // easy to miss. Shift-click extends, like any list.
        .contentShape(Rectangle())
        .onTapGesture { select() }
        .overlay {
            if isSelected { Palette.selection }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Palette.selectionBar).frame(width: 2)
            }
        }
        .contextMenu {
            Button {
                onContextAsk?(row.id)
            } label: {
                Label("Ask Claude", systemImage: "sparkles")
            }
            Button {
                onContextCopy?(row.id)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private func select() {
        onGutterClick(row.id, NSEvent.modifierFlags.contains(.shift))
    }

    private var intralineRanges: (old: [Range<Int>], new: [Range<Int>]) {
        guard let pair = row.emphasisPair else { return ([], []) }
        return IntralineCache.shared.ranges(old: pair.old, new: pair.new)
    }
}

struct HunkHeaderView: View {
    let text: String
    let metrics: DiffMetrics

    var body: some View {
        Text(text)
            .font(.system(size: metrics.numberFontSize, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, Spacing.md)
            // Grows with the type rather than clipping it at the largest sizes.
            .frame(maxWidth: .infinity, minHeight: metrics.fontSize * 1.7, alignment: .leading)
            .background(Palette.surface)
    }
}

public enum DiffLayout: String, CaseIterable, Sendable {
    case sideBySide = "Side by side"
    case unified = "Unified"
}
