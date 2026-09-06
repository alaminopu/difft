import AppKit
import SwiftUI

/// Preference keys, named once so a typo cannot silently split a setting into
/// two independent values.
public enum PrefKey {
    public static let codeFontFamily = "diffFontFamily"
    public static let diffFontSize = "diffFontSize"
    public static let appearance = "appearance"
    public static let diffSplitFraction = "diffSplitFraction"
    public static let syntaxTheme = "syntaxTheme"
}

/// A 4pt grid. Replaces the 14 distinct padding values the UI had grown.
public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
}

/// Corner radii. Replaces the 7 the UI had grown.
public enum Radius {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 8
    public static let lg: CGFloat = 10
}

/// Semantic text roles.
///
/// These exist because the same element was styled several different ways: a
/// file name had four treatments across four files, a directory path three.
/// Naming the role rather than the font is what stops that recurring.
public enum Typography {
    /// Screen title — the PR title, onboarding.
    public static let pageTitle = Font.title2.bold()
    /// Title of a centre-pane view: "Review comments", "Commits".
    public static let sectionTitle = Font.headline
    /// A file name, anywhere it appears.
    public static let fileName = Font.callout.monospaced().bold()
    /// The directory part beside a file name.
    public static let path = Font.caption.monospaced()
    /// Author, age, counts — supporting detail.
    public static let meta = Font.caption
    /// Numeric supporting detail that should not jitter as it changes.
    public static let metaDigits = Font.caption.monospacedDigit()
    /// Text inside a pill or capsule.
    public static let badge = Font.caption.monospacedDigit()
    /// A branch name, sha, or other inline identifier.
    public static let identifier = Font.caption.monospaced()
    /// Body prose: comment bodies, chat, descriptions.
    public static let body = Font.callout
    /// A group header inside a scrolling list.
    public static let groupHeader = Font.callout.bold()

    /// Code, at the user's chosen family and size.
    public static func code(family: String, size: CGFloat) -> Font {
        CodeFont.swiftUIFont(family: family, size: size)
    }
}

/// Semantic colours.
///
/// Diff tints resolve per scheme because a single alpha does not read at equal
/// strength over white and over near-black — the previous code used one value
/// for both and the dark side came out heavy.
public enum Palette {
    // Surfaces
    public static let surface = Color.primary.opacity(0.04)
    public static let surfaceRaised = Color.primary.opacity(0.07)
    public static let hairline = Color.primary.opacity(0.08)
    public static let cardBorder = Color.primary.opacity(0.08)
    /// Behind `inline code` in prose — enough to separate it, not enough to
    /// break the line's rhythm.
    public static let inlineCode = Color.primary.opacity(0.08)

    // States
    public static let selection = Color.accentColor.opacity(0.22)
    public static let selectionBar = Color.accentColor
    public static let hover = Color.accentColor.opacity(0.08)
    public static let activeChip = Color.accentColor.opacity(0.12)

    // Status
    public static let added = Color.green
    public static let removed = Color.red
    public static let mixed = Color.orange
    public static let warning = Color.orange

    // Diff fills, per scheme
    public static func diffAddFill(_ dark: Bool) -> Color {
        Color.green.opacity(dark ? 0.13 : 0.16)
    }
    public static func diffRemoveFill(_ dark: Bool) -> Color {
        Color.red.opacity(dark ? 0.13 : 0.16)
    }
    public static func diffAddGutter(_ dark: Bool) -> Color {
        Color.green.opacity(dark ? 0.20 : 0.24)
    }
    public static func diffRemoveGutter(_ dark: Bool) -> Color {
        Color.red.opacity(dark ? 0.20 : 0.24)
    }
    /// Word-level emphasis, layered over the row fill above.
    public static func diffAddEmphasis(_ dark: Bool) -> Color {
        Color.green.opacity(dark ? 0.34 : 0.30)
    }
    public static func diffRemoveEmphasis(_ dark: Bool) -> Color {
        Color.red.opacity(dark ? 0.34 : 0.30)
    }
    /// The half of a row with no counterpart — dimmed, deliberately not a hole.
    public static func diffFiller(_ dark: Bool) -> Color {
        Color.primary.opacity(dark ? 0.05 : 0.04)
    }
    public static func diffContextGutter(_ dark: Bool) -> Color {
        Color.primary.opacity(dark ? 0.05 : 0.035)
    }
}

/// Diff geometry, derived rather than hardcoded.
///
/// The gutter used to be a fixed 44pt while its font scaled with the size
/// stepper, so a 5-digit line number at 18pt overflowed and — having no line
/// limit — wrapped and grew the row. The total was also written out as a
/// pre-summed `53` in a second file, so changing the gutter moved the columns
/// without moving the split handle.
public struct DiffMetrics: Equatable, Sendable {
    public static let defaultFontSize = 12
    public static let minFontSize = 9
    public static let maxFontSize = 18

    /// Rail overlay width, reserved so it stops covering the code beneath it.
    public static let railWidth: CGFloat = 12

    public let fontSize: CGFloat
    public let numberFontSize: CGFloat
    /// Widest line number in the file, in digits. The gutter is sized for it
    /// and the unified gutter pads to it, so the two cannot drift apart.
    public let digits: Int
    public let gutterWidth: CGFloat
    public let codeInset: CGFloat = Spacing.sm - 2   // 6
    public let gutterTrailing: CGFloat = Spacing.sm  // 8
    public let separatorWidth: CGFloat = 1
    public let dividerWidth: CGFloat = 1
    /// Vertical padding per code line. Compact: IDE-like rather than airy.
    public let rowPadding: CGFloat = 1

    /// - Parameters:
    ///   - digits: widest line number in the file, in digits.
    ///   - unified: unified shows both numbers in one column.
    public init(fontSize: CGFloat, digits: Int, unified: Bool) {
        self.fontSize = fontSize
        self.numberFontSize = fontSize - 1
        self.digits = digits
        // Monospaced digit advance is ~0.6em; +2 keeps a digit from kissing
        // the separator at the largest sizes.
        let digitWidth = (fontSize - 1) * 0.62
        let columns = unified ? (digits * 2 + 1) : digits
        self.gutterWidth = max(unified ? 56 : 28, CGFloat(columns) * digitWidth + 2)
    }

    /// Gutter plus its trailing pad plus the separator — the horizontal cost
    /// of one side's chrome. Both the column maths and the split handle read
    /// this, so they cannot disagree.
    public var totalGutter: CGFloat { gutterWidth + gutterTrailing + separatorWidth }

    /// Digits needed for the largest line number in a file.
    public static func digits(for maxLine: Int) -> Int {
        max(2, String(max(1, maxLine)).count)
    }
}

/// "owner/name" for the open checkout, so a markdown body can turn a bare
/// commit SHA into a link without every call site threading it down.
public struct RepoSlugKey: EnvironmentKey {
    public static let defaultValue: String? = nil
}

public extension EnvironmentValues {
    var repoSlug: String? {
        get { self[RepoSlugKey.self] }
        set { self[RepoSlugKey.self] = newValue }
    }
}
