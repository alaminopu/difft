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

    /// Bumped whenever the palette or font changes, and part of every cache
    /// key: a warm-up still running for the old look can then only fill
    /// entries nobody asks for, never serve stale colours.
    private var generation = 0

    /// Highlights a file's lines ahead of the rows that show them.
    ///
    /// A row highlighted itself when first drawn: a JavaScriptCore call and
    /// an HTML scan per line, on the main thread, so scrolling into fresh
    /// code stuttered while each line went through it. The warmer does the
    /// same per-line work on a queue of its own, with its own Highlightr, into
    /// the same cache — so rows find their colours ready, and look exactly as
    /// they would have.
    private let warmer = HighlightWarmer()

    public init() {
        cache.countLimit = 20_000
    }

    /// Starts highlighting `lines` in the background, in the order given,
    /// replacing any warm-up still running for another file.
    public func prewarm(_ lines: [String], language: String?) {
        guard let language, isDark != nil else { return }
        let prefix = "\(generation)\u{1}\(language)\u{1}"
        var seen = Set<String>()
        let pending = lines.filter {
            $0.count <= Self.maxHighlightedLength
                && seen.insert($0).inserted
                && cache.object(forKey: (prefix + $0) as NSString) == nil
        }
        warmer.start(lines: pending, language: language, keyPrefix: prefix,
                     themeName: theme.themeName(dark: isDark ?? true),
                     font: CodeFont.resolve(family: fontFamily, size: fontSize),
                     cache: cache)
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
    /// Resolved once per theme/font change rather than per access.
    ///
    /// These were computed properties, read from `body` for every emphasis
    /// range of every visible changed row — so a window resize ran a few
    /// hundred `NSFontManager` trait conversions per frame, each of which is a
    /// font-descriptor match.
    public private(set) var emphasisNSFont: NSFont = CodeFont.resolve(
        family: CodeFont.systemFamily, size: CGFloat(DiffMetrics.defaultFontSize))
    public private(set) var emphasisFont: Font = Font(
        CodeFont.resolve(family: CodeFont.systemFamily,
                         size: CGFloat(DiffMetrics.defaultFontSize)) as CTFont)

    private func resolveEmphasisFont() {
        let base = CodeFont.resolve(family: fontFamily, size: fontSize)
        emphasisNSFont = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        emphasisFont = Font(emphasisNSFont as CTFont)
    }

    private func applyTheme() {
        resolveEmphasisFont()
        // Palette must match the window background; a light-theme palette on a
        // dark window is unreadable.
        highlightr?.setTheme(to: theme.themeName(dark: isDark ?? true))
        // Must follow setTheme: it builds a fresh Theme whose init resets the
        // code font to Courier 14.
        highlightr?.theme.setCodeFont(CodeFont.resolve(family: fontFamily, size: fontSize))
        // Every entry is stale once the palette or font changes.
        generation += 1
        warmer.cancel()
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
        // TSX and JSX had no entry, so every React component rendered as
        // plain text — in a TypeScript repository, most of the diff.
        "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "scss": "scss", "less": "less", "xml": "xml", "svg": "xml", "plist": "xml",
        "toml": "ini", "ini": "ini", "sql": "sql", "php": "php", "cs": "csharp",
        "m": "objectivec", "mm": "objectivec", "hpp": "cpp", "cc": "cpp",
        "kts": "kotlin", "scala": "scala", "dart": "dart", "lua": "lua", "r": "r",
        "ex": "elixir", "exs": "elixir", "hs": "haskell", "pl": "perl", "zsh": "bash",
        "bash": "bash", "graphql": "graphql", "gql": "graphql", "proto": "protobuf",
        "tf": "ini", "gradle": "gradle", "cmake": "cmake",
    ]

    /// Files known by name rather than by extension.
    private static let languagesByName: [String: String] = [
        "dockerfile": "dockerfile", "makefile": "makefile", "gemfile": "ruby",
        "rakefile": "ruby", "podfile": "ruby", "cmakelists.txt": "cmake",
    ]

    public static func language(forPath path: String) -> String? {
        languagesByExtension[(path as NSString).pathExtension.lowercased()]
            ?? languagesByName[(path as NSString).lastPathComponent.lowercased()]
    }

    /// Longest line handed to highlight.js.
    ///
    /// Highlighting is a synchronous JavaScriptCore call plus an HTML parse,
    /// on the main actor, per line. A minified bundle or a generated lockfile
    /// can hold a single line of hundreds of kilobytes, and one of those will
    /// stall the window. Matches the cap the intraline diff already applies.
    static let maxHighlightedLength = 2_000

    /// Highlight with language auto-detection (for markdown code blocks
    /// whose fence rarely names the language).
    public func highlightedAuto(_ text: String) -> AttributedString {
        guard text.count <= Self.maxHighlightedLength else { return plain(text) }
        return cached(key: "\(generation)\u{1}\u{1}auto\u{1}\(text)", text: text) { $0.highlight(text) }
    }

    public func highlighted(_ text: String, language: String?) -> AttributedString {
        guard let language, text.count <= Self.maxHighlightedLength else { return plain(text) }
        return cached(key: "\(generation)\u{1}\(language)\u{1}\(text)", text: text) {
            $0.highlight(text, as: language)
        }
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

/// NSCache needs a class; AttributedString is a value type. Written from the
/// warmer's queue and read on the main thread; it never changes after init.
private final class CachedRun: @unchecked Sendable {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

/// The background half of `HighlightService.prewarm`.
///
/// One serial queue and one Highlightr, touched only from that queue: a
/// JavaScriptCore context must not be used from two threads at once, and the
/// main thread's Highlightr is the service's own.
private final class HighlightWarmer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "difft.highlight.warm", qos: .utility)
    private var highlightr: Highlightr?          // queue only
    private var appliedTheme: (name: String, font: NSFont)?  // queue only
    private let lock = NSLock()
    private var token = 0                         // under lock

    private func current(_ t: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == t
    }

    func cancel() {
        lock.lock(); token += 1; lock.unlock()
    }

    func start(lines: [String], language: String, keyPrefix: String,
               themeName: String, font: NSFont, cache: NSCache<NSString, CachedRun>) {
        lock.lock(); token += 1; let mine = token; lock.unlock()
        guard !lines.isEmpty else { return }
        nonisolated(unsafe) let cache = cache
        nonisolated(unsafe) let font = font
        queue.async { [self] in
            guard current(mine) else { return }
            if highlightr == nil { highlightr = Highlightr() }
            guard let highlightr else { return }
            if appliedTheme?.name != themeName || appliedTheme?.font != font {
                // The same two steps, in the same order, as the service's own
                // applyTheme, so the colours match.
                highlightr.setTheme(to: themeName)
                highlightr.theme.setCodeFont(font)
                appliedTheme = (themeName, font)
            }
            for line in lines {
                // Checked per line: opening another file, or changing the
                // theme, abandons the rest at once.
                guard current(mine) else { return }
                let key = (keyPrefix + line) as NSString
                guard cache.object(forKey: key) == nil,
                      let result = highlightr.highlight(line, as: language) else { continue }
                cache.setObject(CachedRun(AttributedString(result)), forKey: key)
            }
        }
    }
}
