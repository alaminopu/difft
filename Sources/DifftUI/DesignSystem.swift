import AppKit
import SwiftUI

/// Preference keys, named once so a typo cannot silently split a setting into
/// two independent values.
public enum PrefKey {
    public static let codeFontFamily = "diffFontFamily"
    public static let diffFontSize = "diffFontSize"
    public static let appearance = "appearance"
    public static let diffSplitFraction = "diffSplitFraction"
    public static let diffLayout = "diffLayout"
    public static let diffDensity = "diffDensity"
    /// Marking a file viewed opens the next unviewed one.
    public static let advanceOnViewed = "advanceOnViewed"
    public static let notifyOnRunFinished = "notifyOnRunFinished"
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

/// Heights of the bars that frame the window, shared so they line up.
public enum Chrome {
    /// The tab bar across the top. Matches a unified titlebar, which is what
    /// centres the traffic lights in it.
    public static let topBar: CGFloat = 52
    /// A pane's own header: the file bar, "Review comments".
    public static let paneHeader: CGFloat = 44
    public static let statusBar: CGFloat = 26
    /// Room the traffic lights need at the leading edge of the top bar.
    public static let trafficLights: CGFloat = 78
}

/// Semantic text roles.
///
/// These exist because the same element was styled several different ways: a
/// file name had four treatments across four files, a directory path three.
/// Naming the role rather than the font is what stops that recurring.
///
/// Sizes are explicit rather than Dynamic Type styles: macOS does not scale
/// them, and `.callout` against `.caption` left the hierarchy to chance.
public enum Typography {
    /// Screen title — the PR title, onboarding.
    public static let pageTitle = Font.system(size: 22, weight: .semibold)
    /// Title of a centre-pane view: "Review comments", "Commits".
    public static let sectionTitle = Font.system(size: 13, weight: .semibold)
    /// A file name, anywhere it appears. Proportional and regular weight: set
    /// in bold monospace, a tree of forty of them read as a wall.
    public static let fileName = Font.system(size: 13)
    /// The directory part beside a file name.
    public static let path = Font.system(size: 11.5, design: .monospaced)
    /// Author, age, counts — supporting detail.
    public static let meta = Font.system(size: 11.5)
    /// Numeric supporting detail that should not jitter as it changes.
    public static let metaDigits = Font.system(size: 11.5).monospacedDigit()
    /// Text inside a pill or capsule.
    public static let badge = Font.system(size: 11, weight: .semibold).monospacedDigit()
    /// A branch name, sha, or other inline identifier.
    public static let identifier = Font.system(size: 11.5, design: .monospaced)
    /// Body prose: comment bodies, chat, descriptions.
    public static let body = Font.system(size: 13)
    /// A control's own label: tabs, buttons, fields.
    public static let control = Font.system(size: 12.5)
    /// A group header inside a scrolling list.
    public static let groupHeader = Font.system(size: 12.5, weight: .semibold)
    /// Small capitals over a group: "IN THIS FILE".
    public static let eyebrow = Font.system(size: 11, weight: .semibold)

    /// Extra leading for prose. Thirteen-point text set solid is what made a
    /// long review comment tiring to read.
    public static let bodyLineSpacing: CGFloat = 3

    /// Code, at the user's chosen family and size.
    public static func code(family: String, size: CGFloat) -> Font {
        CodeFont.swiftUIFont(family: family, size: size)
    }
}

/// Semantic colours, each resolved per appearance.
///
/// Everything here is an explicit value rather than a system material or an
/// opacity of `.primary`. The window used to be whatever translucent grey
/// macOS composed that day, with the code sitting on the same tone as the
/// chrome around it; naming a canvas and a chrome is what lets the diff be
/// the thing you look at.
public enum Palette {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        dynamic(light: hex(light), dark: hex(dark))
    }

    /// Black in light mode, white in dark, at the given strengths.
    private static func ink(light: CGFloat, dark: CGFloat) -> Color {
        dynamic(light: NSColor(white: 0, alpha: light), dark: NSColor(white: 1, alpha: dark))
    }

    // Surfaces
    /// Behind code and long-form content. The darkest surface in dark mode,
    /// the whitest in light.
    public static let canvas = pair(0xFFFFFF, 0x0E1014)
    /// Bars, the sidebar, side panels — everything that frames the canvas.
    public static let chrome = pair(0xF4F5F7, 0x15181D)
    /// A card sitting on the canvas.
    public static let raised = pair(0xFFFFFF, 0x181C22)
    /// A full-width strip inside the canvas: folded lines, hunk headers.
    public static let band = pair(0xF4F5F7, 0x12151A)
    public static let surface = ink(light: 0.035, dark: 0.04)
    /// Opaque, unlike the washes here.
    ///
    /// A popover's own backing is translucent, so content laid on it reads
    /// through to whatever the window is showing underneath — names over a
    /// list of pull requests. Anything floating over the window needs this.
    public static let floating = pair(0xFFFFFF, 0x1B1F26)
    public static let surfaceRaised = ink(light: 0.05, dark: 0.06)
    public static let hairline = ink(light: 0.09, dark: 0.07)
    public static let cardBorder = ink(light: 0.12, dark: 0.10)
    /// A field, or the track of a segmented control.
    public static let control = ink(light: 0.05, dark: 0.06)
    /// The selected segment, lifted off its track.
    public static let controlActive = pair(0xFFFFFF, 0x2A2F39)
    /// Behind `inline code` in prose — enough to separate it, not enough to
    /// break the line's rhythm.
    public static let inlineCode = ink(light: 0.06, dark: 0.08)

    // Text
    public static let textStrong = pair(0x111318, 0xF2F3F5)
    public static let text = pair(0x1F232B, 0xD5D9E0)
    public static let textSecondary = pair(0x5A6372, 0x9AA1AD)
    public static let textTertiary = pair(0x737B89, 0x7C8594)
    public static let lineNumber = pair(0x9AA1AD, 0x5F6775)

    // Accent and states
    public static let accent = pair(0x3F5FE0, 0x7C9CFF)
    /// Text set on a filled accent.
    public static let onAccent = pair(0xFFFFFF, 0x0E1014)
    public static let selection = dynamic(light: hex(0x3F5FE0, alpha: 0.13),
                                          dark: hex(0x7C9CFF, alpha: 0.16))
    public static let selectionBar = accent
    public static let selectionBorder = dynamic(light: hex(0x3F5FE0, alpha: 0.40),
                                                dark: hex(0x7C9CFF, alpha: 0.40))
    public static let hover = ink(light: 0.045, dark: 0.05)
    public static let activeChip = dynamic(light: hex(0x3F5FE0, alpha: 0.10),
                                           dark: hex(0x7C9CFF, alpha: 0.14))

    // Status
    /// Solid marks: rail ticks, change bars, the viewed ring.
    public static let added = pair(0x1F9D63, 0x4CC38A)
    public static let removed = pair(0xD1433C, 0xE5534B)
    /// The same hues tuned to be read as text.
    public static let addedText = pair(0x187A4C, 0x6FCB9F)
    public static let removedText = pair(0xB8322C, 0xF0716A)
    /// An open conversation, something unproven — attention, not alarm.
    public static let amber = pair(0x9A6418, 0xE5B780)
    public static let mixed = pair(0xB8862B, 0xC9A45C)
    public static let warning = amber

    // Diff fills. The `dark` parameter is vestigial — each colour resolves
    // per appearance on its own — and stays so call sites need not change.
    public static func diffAddFill(_ dark: Bool = false) -> Color { addFill }
    public static func diffRemoveFill(_ dark: Bool = false) -> Color { removeFill }
    public static func diffAddGutter(_ dark: Bool = false) -> Color { addGutter }
    public static func diffRemoveGutter(_ dark: Bool = false) -> Color { removeGutter }
    /// Word-level emphasis, layered over the row fill above.
    public static func diffAddEmphasis(_ dark: Bool = false) -> Color { addEmphasis }
    public static func diffRemoveEmphasis(_ dark: Bool = false) -> Color { removeEmphasis }
    /// The half of a row with no counterpart — dimmed, deliberately not a hole.
    public static func diffFiller(_ dark: Bool = false) -> Color { filler }
    public static func diffContextGutter(_ dark: Bool = false) -> Color { .clear }

    // Desaturated on purpose. System green and red at an opacity went muddy
    // over a dark window and neon over a light one.
    private static let addFill = dynamic(light: hex(0x2EA06E, alpha: 0.12), dark: hex(0x2EA06E, alpha: 0.13))
    private static let removeFill = dynamic(light: hex(0xE5534B, alpha: 0.10), dark: hex(0xE5534B, alpha: 0.13))
    private static let addGutter = dynamic(light: hex(0x2EA06E, alpha: 0.20), dark: hex(0x2EA06E, alpha: 0.20))
    private static let removeGutter = dynamic(light: hex(0xE5534B, alpha: 0.17), dark: hex(0xE5534B, alpha: 0.20))
    private static let addEmphasis = dynamic(light: hex(0x2EA06E, alpha: 0.30), dark: hex(0x2EA06E, alpha: 0.40))
    private static let removeEmphasis = dynamic(light: hex(0xE5534B, alpha: 0.26), dark: hex(0xE5534B, alpha: 0.38))
    private static let filler = ink(light: 0.025, dark: 0.025)

    /// A stable colour for a person, for the initials disc beside a comment.
    public static func avatar(for login: String) -> Color {
        let hues: [UInt32] = [0x4A5FA8, 0x3C7A63, 0x8A5A9E, 0x9A6A3A, 0x3F7F93, 0xA0566B]
        let sum = login.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(nsColor: hex(hues[sum % hues.count]))
    }
}

/// How much air a line of code gets.
public enum DiffDensity: String, CaseIterable, Identifiable, Sendable {
    case compact, comfortable, relaxed
    public var id: Self { self }

    public var label: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .relaxed: return "Relaxed"
        }
    }

    /// Vertical padding per code line.
    public var rowPadding: CGFloat {
        switch self {
        case .compact: return 1
        case .comfortable: return 3
        case .relaxed: return 5
        }
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
    /// Vertical padding per code line. Comfortable is about one and a half
    /// line heights in all: at 1pt the rows ran together and a changed line
    /// had no air around it to be seen in.
    public let rowPadding: CGFloat

    /// - Parameters:
    ///   - digits: widest line number in the file, in digits.
    ///   - unified: unified shows both numbers in one column.
    public init(fontSize: CGFloat, digits: Int, unified: Bool,
                density: DiffDensity = .comfortable) {
        self.rowPadding = density.rowPadding
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
