import SwiftUI
import Highlightr

@MainActor
public final class HighlightService: ObservableObject {
    private let highlightr = Highlightr()
    private let cache = NSCache<NSString, NSAttributedString>()

    private var isDark = true

    public init() {
        cache.countLimit = 20_000
        // Default to the dark palette; the root view corrects this from the
        // real SwiftUI colorScheme on appear and on every scheme change
        // (NSApp.effectiveAppearance is unreliable this early in launch).
        applyTheme()
    }

    /// Driven by the root view's `@Environment(\.colorScheme)`.
    public func setDark(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        applyTheme()
    }

    private func applyTheme() {
        // Palette must match the window background; a light-theme palette on a
        // dark window is unreadable. atom-one-dark/light are muted enough that
        // syntax color doesn't fight the diff's red/green tints.
        highlightr?.setTheme(to: isDark ? "atom-one-dark" : "atom-one-light")
        cache.removeAllObjects()
        objectWillChange.send()
    }

    public static func language(forPath path: String) -> String? {
        let map: [String: String] = [
            "swift": "swift", "py": "python", "js": "javascript", "ts": "typescript",
            "rb": "ruby", "go": "go", "rs": "rust", "java": "java", "kt": "kotlin",
            "css": "css", "html": "html", "json": "json", "yml": "yaml", "yaml": "yaml",
            "md": "markdown", "sh": "bash", "vue": "html", "c": "c", "cpp": "cpp", "h": "c",
        ]
        return map[(path as NSString).pathExtension.lowercased()]
    }

    /// Highlight with language auto-detection (for markdown code blocks
    /// whose fence rarely names the language).
    public func highlightedAuto(_ text: String) -> AttributedString {
        guard let highlightr else { return AttributedString(text) }
        let key = "\u{1}auto\u{1}\(text)" as NSString
        if let cached = cache.object(forKey: key) { return AttributedString(cached) }
        guard let result = highlightr.highlight(text) else { return AttributedString(text) }
        cache.setObject(result, forKey: key)
        return AttributedString(result)
    }

    public func highlighted(_ text: String, language: String?) -> AttributedString {
        guard let language, let highlightr else { return AttributedString(text) }
        let key = "\(language)\u{1}\(text)" as NSString
        if let cached = cache.object(forKey: key) { return AttributedString(cached) }
        guard let result = highlightr.highlight(text, as: language) else { return AttributedString(text) }
        cache.setObject(result, forKey: key)
        return AttributedString(result)
    }
}
