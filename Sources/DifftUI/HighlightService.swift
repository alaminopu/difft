import AppKit
import SwiftUI
import Highlightr

@MainActor
public final class HighlightService: ObservableObject {
    private let highlightr = Highlightr()
    /// Caches the bridged `AttributedString`, not the `NSAttributedString`.
    /// The bridge is not free, and it used to run on every call — cache hits
    /// included — for every visible diff row.
    private let cache = NSCache<NSString, CachedRun>()

    /// nil until the first `setDark`, so a light-mode launch cannot flash the
    /// dark palette: `NSApp.effectiveAppearance` is unreliable this early, and
    /// guessing wrong is visible.
    private var isDark: Bool?
    private var fontFamily = CodeFont.systemFamily
    private var fontSize: CGFloat = 12
    private var theme: SyntaxTheme = .atomOne

    public init() {
        cache.countLimit = 20_000
    }

    /// Driven by the root view's resolved appearance.
    public func setDark(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        applyTheme()
    }

    /// The font the diff renders in.
    ///
    /// Highlightr stamps its theme's font onto every highlighted span, and an
    /// explicit font attribute beats the view's `.font(...)` modifier — so
    /// this is the only thing that actually decides the code font. Without it
    /// the theme's Courier 14 default wins and the size stepper does nothing.
    public func setCodeFont(family: String, size: CGFloat) {
        guard family != fontFamily || size != fontSize else { return }
        fontFamily = family
        fontSize = size
        applyTheme()
    }

    public func setTheme(_ theme: SyntaxTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        applyTheme()
    }

    /// A bold cut of the current code font, for word-level emphasis.
    ///
    /// Setting a presentation intent does not reliably bold a run that already
    /// carries a concrete font — and Highlightr gives every run one — so the
    /// bold face is applied explicitly.
    public var emphasisNSFont: NSFont {
        let base = CodeFont.resolve(family: fontFamily, size: fontSize)
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }

    public var emphasisFont: Font { Font(emphasisNSFont as CTFont) }

    private func applyTheme() {
        // Palette must match the window background; a light-theme palette on a
        // dark window is unreadable.
        highlightr?.setTheme(to: theme.themeName(dark: isDark ?? true))
        // Must follow setTheme: it builds a fresh Theme whose init resets the
        // code font to Courier 14.
        highlightr?.theme.setCodeFont(CodeFont.resolve(family: fontFamily, size: fontSize))
        // The cache key covers language and text only, so every entry is stale
        // once the palette or font changes.
        cache.removeAllObjects()
        objectWillChange.send()
    }

    /// Built once, not per call: this is asked for every visible diff row on
    /// every body evaluation, and rebuilding the literal each time was pure
    /// waste.
    private static let languagesByExtension: [String: String] = [
        "swift": "swift", "py": "python", "js": "javascript", "ts": "typescript",
        "rb": "ruby", "go": "go", "rs": "rust", "java": "java", "kt": "kotlin",
        "css": "css", "html": "html", "json": "json", "yml": "yaml", "yaml": "yaml",
        "md": "markdown", "sh": "bash", "vue": "html", "c": "c", "cpp": "cpp", "h": "c",
    ]

    public static func language(forPath path: String) -> String? {
        languagesByExtension[(path as NSString).pathExtension.lowercased()]
    }

    /// Highlight with language auto-detection (for markdown code blocks
    /// whose fence rarely names the language).
    public func highlightedAuto(_ text: String) -> AttributedString {
        cached(key: "\u{1}auto\u{1}\(text)", text: text) { $0.highlight(text) }
    }

    public func highlighted(_ text: String, language: String?) -> AttributedString {
        guard let language else { return plain(text) }
        return cached(key: "\(language)\u{1}\(text)", text: text) { $0.highlight(text, as: language) }
    }

    /// A line no highlighter handled still has to match the chosen font —
    /// otherwise an unrecognised file type renders in a different typeface
    /// and size from the file beside it.
    private func plain(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        attr.font = CodeFont.swiftUIFont(family: fontFamily, size: fontSize)
        return attr
    }

    private func cached(key: String, text: String,
                        run: (Highlightr) -> NSAttributedString?) -> AttributedString {
        guard let highlightr else { return plain(text) }
        let nsKey = key as NSString
        if let hit = cache.object(forKey: nsKey) { return hit.value }
        guard let result = run(highlightr) else { return plain(text) }
        let bridged = AttributedString(result)
        cache.setObject(CachedRun(bridged), forKey: nsKey)
        return bridged
    }
}

/// NSCache needs a class; AttributedString is a value type.
private final class CachedRun {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}
