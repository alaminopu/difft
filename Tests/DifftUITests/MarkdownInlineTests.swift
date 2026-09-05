import XCTest
import SwiftUI
@testable import DifftUI

/// Review comments are mostly identifiers, so `backticked spans` carrying no
/// visual distinction from prose was a real readability loss.
final class MarkdownInlineTests: XCTestCase {
    private func codeRuns(_ markdown: String) -> [String] {
        let attr = MarkdownBodyView.inline(markdown, codeFamily: CodeFont.systemFamily)
        return attr.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true
                ? String(attr[run.range].characters) : nil
        }
    }

    func testBacktickedSpanIsMarkedAsCode() {
        XCTAssertEqual(codeRuns("call `supports_integration_type()` first"),
                       ["supports_integration_type()"])
    }

    func testCodeRunsCarryAMonospacedFont() {
        let attr = MarkdownBodyView.inline("use `foo` here", codeFamily: CodeFont.systemFamily)
        let codeRun = attr.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertNotNil(codeRun?.font, "inline code must get a font of its own, not inherit the prose font")
    }

    func testMultipleSpansAreAllStyled() {
        XCTAssertEqual(codeRuns("`a` and `b` and `c`"), ["a", "b", "c"])
    }

    func testProseWithoutBackticksHasNoCodeRuns() {
        XCTAssertTrue(codeRuns("just ordinary prose").isEmpty)
    }

    /// Bold and links must keep working alongside the code styling.
    func testOtherInlineMarkdownStillParses() {
        let attr = MarkdownBodyView.inline("**bold** and `code`", codeFamily: CodeFont.systemFamily)
        XCTAssertTrue(String(attr.characters).contains("bold"))
        XCTAssertFalse(String(attr.characters).contains("**"), "bold markers should be consumed")
        XCTAssertEqual(codeRuns("**bold** and `code`"), ["code"])
    }

    /// Malformed markdown must render as text rather than vanish.
    func testUnclosedBacktickFallsBackToPlainText() {
        let attr = MarkdownBodyView.inline("an `unclosed span", codeFamily: CodeFont.systemFamily)
        XCTAssertTrue(String(attr.characters).contains("unclosed span"))
    }
}
