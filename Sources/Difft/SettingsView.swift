import SwiftUI
import DifftUI

/// The ⌘, window. Appearance and the diff's typography used to live in the
/// View menu and a toolbar stepper, which is no place for settings you set
/// once — and left no room for the font choice at all.
struct SettingsView: View {
    @AppStorage(PrefKey.appearance) private var appearance = AppAppearance.system
    @AppStorage(PrefKey.codeFontFamily) private var codeFontFamily = CodeFont.systemFamily
    @AppStorage(PrefKey.diffFontSize) private var diffFontSize = DiffMetrics.defaultFontSize
    @AppStorage(PrefKey.syntaxTheme) private var syntaxTheme = SyntaxTheme.atomOne

    /// Enumerated once per window rather than per keystroke — scanning every
    /// installed family is not free.
    private let families = CodeFont.installedFamilies()

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                Picker("Syntax colours", selection: $syntaxTheme) {
                    ForEach(SyntaxTheme.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Diff") {
                Picker("Code font", selection: $codeFontFamily) {
                    Text(CodeFont.systemLabel).tag(CodeFont.systemFamily)
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $diffFontSize,
                        in: DiffMetrics.minFontSize...DiffMetrics.maxFontSize) {
                    Text("Size: \(diffFontSize)pt")
                }
                LabeledContent("Preview") {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(preview)
                            .font(Typography.code(family: codeFontFamily,
                                                  size: CGFloat(diffFontSize)))
                            .textSelection(.enabled)
                        Text("Zero and capital O, one and lowercase L, brackets, operators.")
                            .font(Typography.meta)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.sm))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Characters that separate a good code font from a bad one: the glyphs
    /// that get confused for each other, and the operators a ligature font
    /// draws as one mark.
    ///
    /// `->` is written literally rather than as an arrow — a font with
    /// ligatures is exactly one that turns it into an arrow, so a literal
    /// arrow here would look identical in every font and test nothing.
    private var preview: String { "0O1lI  {}[]  ->  ==  !=  <=" }
}
