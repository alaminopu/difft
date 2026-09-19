import SwiftUI
import DifftCore
import DifftServices
import DifftUI

/// The ⌘, window.
///
/// Four tabs rather than one form: what the app looks like, how code is set,
/// how a review behaves, and the keys. It was a single grouped list with four
/// rows, which left nowhere for a setting to go and showed none of their
/// effects — every choice here is previewed on a real diff.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            DiffSettings()
                .tabItem { Label("Diff", systemImage: "text.alignleft") }
            ReviewSettings()
                .tabItem { Label("Review", systemImage: "checklist") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 620)
        .tint(Palette.accent)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(PrefKey.appearance) private var appearance = AppAppearance.system
    @AppStorage(PrefKey.syntaxTheme) private var syntaxTheme = SyntaxTheme.atomOne

    var body: some View {
        SettingsPage {
            SettingsSection("Theme") {
                HStack(spacing: Spacing.md) {
                    ForEach(AppAppearance.allCases) { option in
                        ThemeSwatch(option: option, selected: option == appearance) {
                            appearance = option
                        }
                    }
                }
            }
            SettingsSection("Syntax colours",
                            footer: "Each is a light and dark pair, chosen to stay legible "
                                + "behind the diff's red and green.") {
                SegmentedControl(selection: $syntaxTheme,
                                 options: SyntaxTheme.allCases.map { ($0, $0.label) })
            }
            DiffPreview()
        }
    }
}

/// A miniature of the window in each appearance, so the choice is seen rather
/// than read.
private struct ThemeSwatch: View {
    let option: AppAppearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.sm) {
                HStack(spacing: 0) {
                    if option != .dark { miniature(dark: false) }
                    if option != .light { miniature(dark: true) }
                }
                .frame(height: 74)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(selected ? Palette.accent : Palette.cardBorder,
                                      lineWidth: selected ? 2 : 1)
                }
                Text(option.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.textStrong : Palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func miniature(dark: Bool) -> some View {
        let chrome = dark ? Color(red: 0.08, green: 0.09, blue: 0.11) : Color(red: 0.96, green: 0.96, blue: 0.97)
        let canvas = dark ? Color(red: 0.055, green: 0.063, blue: 0.078) : .white
        let ink = dark ? Color.white.opacity(0.35) : Color.black.opacity(0.3)
        return VStack(spacing: 0) {
            chrome.frame(height: 12)
            HStack(spacing: 0) {
                chrome.frame(width: 26)
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(ink).frame(width: 44, height: 3)
                    Capsule().fill(Color.red.opacity(0.45)).frame(width: 58, height: 3)
                    Capsule().fill(Color.green.opacity(0.5)).frame(width: 52, height: 3)
                    Capsule().fill(ink).frame(width: 36, height: 3)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(canvas)
            }
        }
    }
}

// MARK: - Diff

private struct DiffSettings: View {
    @AppStorage(PrefKey.codeFontFamily) private var codeFontFamily = CodeFont.systemFamily
    @AppStorage(PrefKey.diffFontSize) private var diffFontSize = DiffMetrics.defaultFontSize
    @AppStorage(PrefKey.diffDensity) private var density = DiffDensity.comfortable
    @AppStorage(PrefKey.diffLayout) private var layout = DiffLayout.sideBySide

    /// Enumerated once per window rather than per keystroke — scanning every
    /// installed family is not free.
    private let families = CodeFont.installedFamilies()

    var body: some View {
        SettingsPage {
            SettingsSection("Code font") {
                SettingsRow("Family") {
                    Picker("Family", selection: $codeFontFamily) {
                        Text(CodeFont.systemLabel).tag(CodeFont.systemFamily)
                        if CodeFont.bundledAvailable {
                            Text("SF Mono (System)").tag(CodeFont.sfMonoFamily)
                        }
                        Divider()
                        ForEach(families, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 240)
                }
                SettingsRow("Size") {
                    HStack(spacing: Spacing.md) {
                        Slider(value: Binding(get: { Double(diffFontSize) },
                                              set: { diffFontSize = Int($0.rounded()) }),
                               in: Double(DiffMetrics.minFontSize)...Double(DiffMetrics.maxFontSize),
                               step: 1)
                            .frame(width: 180)
                        Text("\(diffFontSize) pt").font(Typography.metaDigits)
                            .foregroundStyle(Palette.textSecondary).frame(width: 40, alignment: .trailing)
                    }
                }
                SettingsRow("Line spacing") {
                    SegmentedControl(selection: $density,
                                     options: DiffDensity.allCases.map { ($0, $0.label) })
                }
            }
            SettingsSection("Layout") {
                SettingsRow("Open files in") {
                    SegmentedControl(selection: $layout,
                                     options: [(.sideBySide, "Split"), (.unified, "Unified")])
                }
            }
            DiffPreview()
            // `->` is written literally rather than as an arrow — a font with
            // ligatures is exactly one that turns it into an arrow, so a
            // literal arrow here would look identical in every font.
            Text("0O1lI  {}[]  ->  ==  !=  <=")
                .font(Typography.code(family: codeFontFamily, size: CGFloat(diffFontSize)))
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .help("Zero and capital O, one and lowercase L, brackets, operators.")
        }
    }
}

// MARK: - Review

private struct ReviewSettings: View {
    @AppStorage(PrefKey.advanceOnViewed) private var advanceOnViewed = true
    @AppStorage(PrefKey.notifyOnRunFinished) private var notify = true
    @AppStorage(ShellPref.showPanel) private var showQueue = true
    @AppStorage(FileListPref.unviewedOnly) private var unviewedOnly = false
    @AppStorage(FileListPref.flat) private var flat = false

    var body: some View {
        SettingsPage {
            SettingsSection("Reading") {
                SettingsToggle("Open the next file after marking one viewed",
                               detail: "Mark viewed, or V, moves on to the next file you have not been through.",
                               isOn: $advanceOnViewed)
                SettingsToggle("Show the review queue",
                               detail: "Open threads, findings and unviewed files beside the diff. \u{2325}\u{2318}0 toggles it.",
                               isOn: $showQueue)
            }
            SettingsSection("File list") {
                SettingsToggle("Hide files already viewed", detail: nil, isOn: $unviewedOnly)
                SettingsToggle("Flat list instead of folders", detail: nil, isOn: $flat)
            }
            SettingsSection("Claude") {
                SettingsToggle("Notify when a run finishes",
                               detail: "A walkthrough or a review takes a couple of minutes. "
                                   + "Only when Difft is in the background.",
                               isOn: $notify)
            }
            SettingsSection("Storage",
                            footer: "Viewed files, notes, findings and each pull request's worktree. "
                                + "Worktrees untouched for a week are removed at launch.") {
                SettingsRow("Difft keeps its data in") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppModel.appSupportDir])
                    }
                }
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    var body: some View {
        SettingsPage {
            ForEach(ShortcutSheet.groups, id: \.title) { group in
                SettingsSection(group.title) {
                    ForEach(group.rows, id: \.what) { row in
                        HStack {
                            Text(row.what).font(Typography.body).foregroundStyle(Palette.text)
                            Spacer()
                            Text(row.keys)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
            Text("Single-letter keys work while the diff has focus; click in it once first.")
                .font(Typography.meta).foregroundStyle(Palette.textTertiary)
        }
    }
}

// MARK: - Preview

/// A real diff, drawn by the real renderer, so font, size, spacing, syntax
/// colours and appearance all show their effect as they change.
private struct DiffPreview: View {
    @AppStorage(PrefKey.diffFontSize) private var diffFontSize = DiffMetrics.defaultFontSize
    @AppStorage(PrefKey.diffLayout) private var layout = DiffLayout.sideBySide
    @State private var selection: LineSelection?

    private static let sample: FileDiff = {
        func line(_ kind: LineKind, _ old: Int?, _ new: Int?, _ text: String) -> DiffLine {
            DiffLine(kind: kind, oldNumber: old, newNumber: new, text: text)
        }
        return FileDiff(path: "Preview.swift", kind: .modified, hunks: [Hunk(header: "", lines: [
            line(.context, 12, 12, "func total(_ items: [Item]) -> Int {"),
            line(.deletion, 13, nil, "    items.map(\\.price).sum()"),
            line(.addition, nil, 13, "    // Quantity was ignored."),
            line(.addition, nil, 14, "    items.map { $0.price * $0.count }.sum()"),
            line(.context, 14, 15, "}"),
        ])])
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("PREVIEW").font(Typography.eyebrow).kerning(0.6)
                .foregroundStyle(Palette.textTertiary)
            FileDiffView(file: Self.sample, layout: .constant(layout), selection: $selection,
                         fontSize: diffFontSize, onAsk: { _, _ in })
                .frame(height: 150)
                .background(Palette.canvas)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Palette.cardBorder) }
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Building blocks

private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) { content }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title.uppercased()).font(Typography.eyebrow).kerning(0.6)
                .foregroundStyle(Palette.textTertiary)
            VStack(alignment: .leading, spacing: Spacing.md) { content }
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
                .overlay { RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Palette.hairline) }
            if let footer {
                Text(footer).font(Typography.meta).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let label: String
    let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(label).font(Typography.body).foregroundStyle(Palette.text)
            Spacer(minLength: Spacing.lg)
            control
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String?, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.body).foregroundStyle(Palette.text)
                if let detail {
                    Text(detail).font(Typography.meta).foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.lg)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}
