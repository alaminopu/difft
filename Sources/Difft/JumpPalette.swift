import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// ⌘K: type a few letters of a file name and land in it.
///
/// On a forty-file pull request the tree is a place to see progress, not a
/// way to get around — finding `relations.py` by scrolling and unfolding is
/// slower than typing "rel". `name:120` opens the file at a line.
struct JumpPalette: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private enum Target: Identifiable {
        case tab(ReviewTab)
        case file(FileDiff)

        var id: String {
            switch self {
            case .tab(let tab): return "tab:\(tab.rawValue)"
            case .file(let file): return "file:\(file.path)"
            }
        }
    }

    private static let limit = 12

    private var parsed: (query: String, line: Int?) { FuzzyMatch.splitLine(query) }

    private var results: [Target] {
        let text = parsed.query.trimmingCharacters(in: .whitespaces)
        let viewed = model.session?.data.viewedFiles ?? []
        guard !text.isEmpty else {
            // Nothing typed: what is left to read, in order.
            return model.files.filter { !viewed.contains($0.path) }
                .prefix(Self.limit).map(Target.file)
        }
        let files = FuzzyMatch.rank(model.files, query: text) { $0.path }.map(Target.file)
        // A line number only makes sense for a file.
        let tabs = parsed.line == nil
            ? FuzzyMatch.rank(ReviewTab.allCases, query: text) { $0.label }.map(Target.tab) : []
        return Array((tabs + files).prefix(Self.limit))
    }

    var body: some View {
        let results = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.textTertiary)
                    TextField("File name, name:line, or a tab", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { open(results) }
                        .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                        .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                        .onKeyPress(.escape) { isPresented = false; return .handled }
                }
                .padding(.horizontal, Spacing.lg)
                .frame(height: 46)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                if results.isEmpty {
                    Text("No file matches")
                        .font(Typography.control).foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, Spacing.xl)
                } else {
                    VStack(spacing: 1) {
                        if query.isEmpty {
                            Text("NOT VIEWED YET")
                                .font(Typography.eyebrow).kerning(0.6)
                                .foregroundStyle(Palette.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.sm).padding(.bottom, Spacing.xs)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, target in
                            row(target, active: index == highlighted)
                                .onTapGesture { highlighted = index; open(results) }
                        }
                    }
                    .padding(Spacing.sm)
                }
            }
            .frame(width: 560)
            .background(Palette.floating, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.cardBorder) }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func row(_ target: Target, active: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            switch target {
            case .tab(let tab):
                Image(systemName: "arrow.turn.down.right").font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary).frame(width: 16)
                Text(tab.label).font(Typography.body).foregroundStyle(Palette.textStrong)
                Spacer(minLength: 0)
                Text("Tab").font(Typography.meta).foregroundStyle(Palette.textTertiary)
            case .file(let file):
                let name = String(file.path.split(separator: "/").last ?? "")
                let dir = file.path.split(separator: "/").dropLast().joined(separator: "/")
                Image(systemName: "doc").font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary).frame(width: 16)
                Text(name).font(Typography.body).foregroundStyle(Palette.textStrong)
                Text(dir).font(Typography.path).foregroundStyle(Palette.textTertiary)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                if let line = parsed.line {
                    Text("line \(line)").font(Typography.metaDigits)
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .frame(height: 30)
        .background(active ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, in results: [Target]) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + results.count) % results.count
    }

    private func open(_ results: [Target]) {
        guard results.indices.contains(highlighted) else { return }
        switch results[highlighted] {
        case .tab(let tab): model.show(tab)
        case .file(let file): model.open(file: file.path, line: parsed.line)
        }
        isPresented = false
    }
}
