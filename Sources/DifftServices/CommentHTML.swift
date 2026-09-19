import Foundation

/// Turns the HTML that review bots write into the markdown the app renders.
///
/// GitHub accepts a subset of HTML in comments and the bots lean on it:
/// shields.io badges, `<details>` folds, `<code>` and `<b>` for emphasis. The
/// app renders markdown, not HTML, so all of that arrived as literal angle
/// brackets — a bot's review was the least readable thing on the page. This
/// does not try to be a browser. It maps the tags that carry meaning onto
/// markdown and drops the ones that only carry layout.
public enum CommentHTML {
    private static let replacements: [(pattern: String, template: String)] = [
        // Badges say nothing a reader needs; their alt text does.
        (#"<img\b[^>]*\balt="([^"]*)"[^>]*>"#, "$1"),
        (#"<img\b[^>]*>"#, ""),
        // A link wrapped in <code> stays a link: in backticks it would be
        // literal text, and these are the bot's pointers into the code.
        (#"<code>\s*(\[[^<]*\]\([^<)\s]*\))\s*</code>"#, "$1  "),
        (#"</?(?:code|tt|kbd)>"#, "`"),
        (#"</?(?:b|strong)>"#, "**"),
        (#"</?(?:i|em)>"#, "*"),
        (#"<br\s*/?>"#, "\n"),
        (#"<summary>(.*?)</summary>"#, "\n**$1**\n"),
        (#"</?(?:details|summary|pre|sub|sup|p|div|span|table|tbody|thead|tr|td|th|picture|source|h[1-6]|ul|ol|li|hr|blockquote)\b[^>]*>"#, "\n"),
        (#"<!--.*?-->"#, ""),
    ]

    private static let compiled: [(NSRegularExpression, String)] = replacements.compactMap {
        guard let regex = try? NSRegularExpression(
            pattern: $0.pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        return (regex, $0.template)
    }

    /// Markdown for `body`, with its HTML mapped or removed. Text inside
    /// fenced code blocks is left exactly as written.
    public static func markdown(from body: String) -> String {
        // Cheap exit: most human comments contain no markup at all.
        guard body.contains("<") else { return body }
        // Views ask for this from `body`, so every re-render of a thread list
        // would otherwise run a dozen regular expressions per comment again.
        let key = body as NSString
        if let hit = cache.object(forKey: key) { return hit as String }
        let converted = convertBody(body)
        cache.setObject(converted as NSString, forKey: key)
        return converted
    }

    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()

    private static func convertBody(_ body: String) -> String {
        var out: [String] = []
        var prose: [String] = []
        var inFence = false
        func flush() {
            guard !prose.isEmpty else { return }
            out.append(convert(prose.joined(separator: "\n")))
            prose = []
        }
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !inFence { flush() }
                out.append(line)
                inFence.toggle()
            } else if inFence {
                out.append(line)
            } else {
                prose.append(line)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    private static let anchor = try? NSRegularExpression(
        pattern: #"<a\b[^>]*\bhref="([^"]*)"[^>]*>(.*?)</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// `<a href>` to a markdown link. Done by hand rather than with a regex
    /// template because the link text has to be escaped: bots link to
    /// "file.py[956-969]", and an unescaped bracket inside the label ends the
    /// label early and leaves the whole thing as literal text.
    private static func convertAnchors(_ text: String) -> String {
        guard let anchor else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in anchor.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let url = ns.substring(with: match.range(at: 1))
            let label = ns.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            result += "[\(label)](\(url))"
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }

    private static func convert(_ text: String) -> String {
        var result = convertAnchors(text)
        for (regex, template) in compiled {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        result = result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        // Dropped block tags leave runs of blank lines behind.
        return result.replacingOccurrences(of: #"\n[ \t]*(\n[ \t]*){2,}"#, with: "\n\n",
                                           options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
