import XCTest
import AppKit
import SwiftUI
@testable import DifftUI

/// Guards the regression that made the font-size stepper inert.
///
/// Highlightr's `Theme.init` sets Courier 14 and stamps `.font` onto every
/// highlighted span; an explicit font attribute in an `AttributedString` beats
/// the view's `.font(...)` modifier. So unless the service pushes the chosen
/// font into the theme, every highlighted line renders Courier 14 no matter
/// what the user picks.
@MainActor
final class HighlightServiceTests: XCTestCase {
    private func font(of attributed: AttributedString) -> NSFont? {
        let ns = NSAttributedString(attributed)
        guard ns.length > 0 else { return nil }
        return ns.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    func testHighlightedCodeUsesTheRequestedSize() throws {
        let service = HighlightService()
        service.setDark(true)
        service.setCodeFont(family: CodeFont.systemFamily, size: 17)
        let attributed = service.highlighted("let x = 1", language: "swift")
        let resolved = try XCTUnwrap(font(of: attributed))
        XCTAssertEqual(resolved.pointSize, 17, "the size stepper must reach highlighted code")
        XCTAssertNotEqual(resolved.familyName, "Courier", "Highlightr's default leaked through")
    }

    func testHighlightedCodeUsesTheRequestedFamily() throws {
        try XCTSkipIf(NSFont(name: "Menlo", size: 12) == nil, "Menlo not installed")
        let service = HighlightService()
        service.setDark(true)
        service.setCodeFont(family: "Menlo", size: 14)
        let attributed = service.highlighted("def f(): pass", language: "python")
        let resolved = try XCTUnwrap(font(of: attributed))
        XCTAssertEqual(resolved.familyName, "Menlo")
        XCTAssertEqual(resolved.pointSize, 14)
    }

    /// Changing size after the cache is warm must not serve the old size.
    func testChangingSizeInvalidatesCachedRuns() throws {
        let service = HighlightService()
        service.setDark(true)
        service.setCodeFont(family: CodeFont.systemFamily, size: 10)
        _ = service.highlighted("let x = 1", language: "swift")
        service.setCodeFont(family: CodeFont.systemFamily, size: 16)
        let after = try XCTUnwrap(font(of: service.highlighted("let x = 1", language: "swift")))
        XCTAssertEqual(after.pointSize, 16)
    }

    /// Switching light/dark rebuilds the theme, which resets the code font —
    /// it has to be reapplied after, or the font silently reverts.
    func testSchemeChangeDoesNotResetTheCodeFont() throws {
        let service = HighlightService()
        service.setDark(true)
        service.setCodeFont(family: CodeFont.systemFamily, size: 15)
        service.setDark(false)
        let after = try XCTUnwrap(font(of: service.highlighted("let x = 1", language: "swift")))
        XCTAssertEqual(after.pointSize, 15)
        XCTAssertNotEqual(after.familyName, "Courier")
    }

    /// A file type with no highlighter must still match the file beside it.
    func testUnhighlightedTextCarriesTheSameFont() throws {
        let service = HighlightService()
        service.setCodeFont(family: CodeFont.systemFamily, size: 13)
        let attributed = service.highlighted("some plain text", language: nil)
        XCTAssertNotNil(attributed.font, "unrecognised file types must not fall back to body font")
    }

    func testLanguageDetectionFromPath() {
        XCTAssertEqual(HighlightService.language(forPath: "a/b/c.swift"), "swift")
        XCTAssertEqual(HighlightService.language(forPath: "x.YML"), "yaml")
        XCTAssertNil(HighlightService.language(forPath: "Package.resolved"))
    }
}

extension HighlightServiceTests {
    /// Proves the font assertions above exercise the real highlighter rather
    /// than the plain-text fallback, which sets the font itself and would pass
    /// regardless.
    func testSwiftHighlightingActuallyProducesColouredRuns() throws {
        let service = HighlightService()
        service.setDark(true)
        service.setCodeFont(family: CodeFont.systemFamily, size: 12)
        let attributed = service.highlighted("let x = 1 // note", language: "swift")
        let ns = NSAttributedString(attributed)
        var colours: Set<String> = []
        ns.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
            if let c = value as? NSColor { colours.insert(c.description) }
        }
        XCTAssertGreaterThan(colours.count, 1,
                             "expected syntax colouring; a single colour means Highlightr never ran")
    }
}

extension HighlightServiceTests {
    /// Word-level emphasis must be a bold cut of the *same* font at the *same*
    /// size — a different size would shift the line's metrics mid-line.
    func testEmphasisFontIsABoldCutOfTheCodeFont() {
        let service = HighlightService()
        service.setCodeFont(family: CodeFont.systemFamily, size: 13)
        let emphasis = service.emphasisNSFont
        XCTAssertEqual(emphasis.pointSize, 13)
        XCTAssertTrue(NSFontManager.shared.traits(of: emphasis).contains(.boldFontMask),
                      "emphasis should be bold")
        XCTAssertTrue(emphasis.isFixedPitch, "emphasis must stay monospaced")
    }

    func testEmphasisFontTracksTheChosenFamily() throws {
        try XCTSkipIf(NSFont(name: "Menlo", size: 12) == nil, "Menlo not installed")
        let service = HighlightService()
        service.setCodeFont(family: "Menlo", size: 16)
        XCTAssertEqual(service.emphasisNSFont.familyName, "Menlo")
        XCTAssertEqual(service.emphasisNSFont.pointSize, 16)
    }
}
