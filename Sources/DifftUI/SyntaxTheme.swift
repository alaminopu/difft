import Foundation

/// A light/dark pair of Highlightr themes.
///
/// The pair matters more than either half: the palette has to match the window
/// background, and a light palette on a dark window is unreadable. Highlightr
/// ships 271 themes; these are the pairs that stay legible behind the diff's
/// red and green washes.
public enum SyntaxTheme: String, CaseIterable, Identifiable, Sendable {
    case atomOne, xcode, github, nord, solarized

    public var id: Self { self }

    public var label: String {
        switch self {
        case .atomOne: return "Atom One"
        case .xcode: return "Xcode"
        case .github: return "GitHub"
        case .nord: return "Nord"
        case .solarized: return "Solarized"
        }
    }

    public func themeName(dark: Bool) -> String {
        switch self {
        case .atomOne: return dark ? "atom-one-dark" : "atom-one-light"
        case .xcode: return dark ? "xcode-dark" : "xcode"
        case .github: return dark ? "github-dark" : "github"
        case .nord: return dark ? "nord" : "atom-one-light"   // Nord ships dark only
        case .solarized: return dark ? "solarized-dark" : "solarized-light"
        }
    }
}
