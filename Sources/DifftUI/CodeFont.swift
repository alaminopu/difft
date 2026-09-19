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
    /// Stored value meaning "the default", which is the bundled font. Empty
    /// because it always was: every existing preference file already holds it.
    public static let systemFamily = ""

    /// Stored value meaning SF Mono, which has no public family name.
    public static let sfMonoFamily = "SF Mono"

    /// JetBrains Mono, without ligatures. A review tool should show the
    /// characters that were typed: a font that draws `!=` as one glyph is
    /// pleasant to write in and a small lie to review in.
    public static let bundledFamily = "JetBrains Mono NL"

    /// Label for the default in a picker.
    public static var systemLabel: String {
        bundledAvailable ? "JetBrains Mono (Default)" : "SF Mono (System)"
    }

    public static var bundledAvailable: Bool {
        _ = registration
        return NSFont(name: bundledFamily, size: 12) != nil
    }

    /// Registers the font files shipped with the app, once per process.
    ///
    /// Looked up by hand rather than through `Bundle.module`: SwiftPM's
    /// generated accessor cannot find a resource bundle inside a signed .app
    /// and traps when it fails (see Vendor/Highlightr/PATCH.md). A missing
    /// font here just means SF Mono.
    public static func registerBundledFonts() { _ = registration }

    private static let registration: Void = {
        let name = "Difft_DifftUI.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            let bundle = root.appendingPathComponent(name)
            guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)
            else { continue }
            let fonts = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "ttf" }
            guard !fonts.isEmpty else { continue }
            CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
            return
        }
    }()

    /// Monospaced families installed on this machine.
    ///
    /// SF Mono is not among them — it ships with macOS but is not exposed by
    /// family name, so it is offered separately via `sfMonoFamily` and
    /// resolved through `NSFont.monospacedSystemFont`. Nor is the bundled
    /// font, which is offered as the default.
    public static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { $0 != bundledFamily && NSFont(name: $0, size: 12)?.isFixedPitch == true }
            .sorted()
    }

    /// The font to render code in. Falls back — to the bundled font, then to
    /// SF Mono — when the stored family is empty or no longer installed:
    /// uninstalling a font must not leave the diff unrenderable.
    public static func resolve(family: String, size: CGFloat) -> NSFont {
        _ = registration
        if family != sfMonoFamily {
            if !family.isEmpty, let font = NSFont(name: family, size: size) { return font }
            if let bundled = NSFont(name: bundledFamily, size: size) { return bundled }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// SwiftUI equivalent, for the text that is not routed through Highlightr.
    public static func swiftUIFont(family: String, size: CGFloat) -> Font {
        Font(resolve(family: family, size: size) as CTFont)
    }
}
