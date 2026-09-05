import AppKit
import SwiftUI

/// Resolves the monospaced font the diff renders in.
///
/// This exists because Highlightr bakes a font into the attributed string it
/// returns — its `Theme.init` sets Courier 14 and stamps `.font` onto every
/// span — and an explicit font attribute beats the view's `.font(...)`
/// modifier. So the chosen font has to be pushed *into* the highlighter, not
/// applied around it, and that means one place has to own resolving it.
public enum CodeFont: Sendable {
    /// Stored value meaning "SF Mono", which has no public family name.
    public static let systemFamily = ""

    /// Label for the system font in a picker.
    public static let systemLabel = "SF Mono (System)"

    /// Monospaced families installed on this machine.
    ///
    /// SF Mono is not among them — it ships with macOS but is not exposed by
    /// family name, so it is offered separately via `systemFamily` and
    /// resolved through `NSFont.monospacedSystemFont`.
    public static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
            .sorted()
    }

    /// The font to render code in. Falls back to SF Mono when the stored
    /// family is empty or no longer installed — uninstalling a font must not
    /// leave the diff unrenderable.
    public static func resolve(family: String, size: CGFloat) -> NSFont {
        guard !family.isEmpty, let font = NSFont(name: family, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    /// SwiftUI equivalent, for the text that is not routed through Highlightr.
    public static func swiftUIFont(family: String, size: CGFloat) -> Font {
        guard !family.isEmpty, NSFont(name: family, size: size) != nil else {
            return .system(size: size, design: .monospaced)
        }
        return .custom(family, fixedSize: size)
    }
}
