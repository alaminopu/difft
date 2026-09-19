import XCTest
@testable import DifftServices

final class CommentHTMLTests: XCTestCase {
    func testPlainMarkdownIsUntouched() {
        let body = "Looks good. `x < y` is fine here.\n\n- one\n- two"
        XCTAssertEqual(CommentHTML.markdown(from: "no markup at all"), "no markup at all")
        // A bare `<` with no tag after it must survive.
        XCTAssertEqual(CommentHTML.markdown(from: body), body)
    }

    func testInlineTagsBecomeMarkdown() {
        XCTAssertEqual(CommentHTML.markdown(from: "Use <code>foo()</code> and <b>never</b> <i>bar</i>."),
                       "Use `foo()` and **never** *bar*.")
    }

    func testBadgeCollapsesToItsAltText() {
        let body = #"<img src="https://img.shields.io/badge/High-634FD1" height="20px" alt="Action required">"#
        XCTAssertEqual(CommentHTML.markdown(from: body), "Action required")
    }

    func testImageWithoutAltDisappears() {
        XCTAssertEqual(CommentHTML.markdown(from: #"before <img src="x.png"> after"#), "before  after")
    }

    func testLinkBecomesMarkdownLink() {
        XCTAssertEqual(CommentHTML.markdown(from: #"see <a href="https://example.com/x">the docs</a>"#),
                       "see [the docs](https://example.com/x)")
    }

    /// Review bots link to "file.py[956-969]"; an unescaped bracket in the
    /// label ends it early and the link renders as literal markdown.
    func testBracketsInLinkTextAreEscaped() {
        XCTAssertEqual(
            CommentHTML.markdown(from: #"<a href="https://example.com/f.py#L9">f.py[9-12]</a>"#),
            #"[f.py\[9-12\]](https://example.com/f.py#L9)"#)
    }

    func testLinkInsideCodeTagsStaysALink() {
        let out = CommentHTML.markdown(from: "<code>[f.py[7-29]](https://example.com/f.py#L7)</code>")
        XCTAssertEqual(out, "[f.py[7-29]](https://example.com/f.py#L7)")
    }

    func testDetailsFoldKeepsItsSummaryAsAHeading() {
        let body = "<details>\n<summary><strong>Evidence</strong></summary>\n\n<pre>\nsome text\n</pre>\n</details>"
        let out = CommentHTML.markdown(from: body)
        XCTAssertTrue(out.contains("Evidence"))
        XCTAssertTrue(out.contains("some text"))
        XCTAssertFalse(out.contains("<"), out)
    }

    func testNestedSubTagsFromCodexBadgesAreRemoved() {
        XCTAssertEqual(CommentHTML.markdown(from: "<sub><sub>P2 Badge</sub></sub>  Preserve None filtering"),
                       "P2 Badge\n\n  Preserve None filtering".replacingOccurrences(of: "\n\n  ", with: "\n\n  "))
    }

    /// Code is quoted, not written: `<T>` in a snippet is a generic, not a tag.
    func testFencedCodeIsLeftExactlyAsWritten() {
        let body = "Try:\n```swift\nlet x: Array<Int> = []\n<b>not bold</b>\n```\n<b>bold</b>"
        let out = CommentHTML.markdown(from: body)
        XCTAssertTrue(out.contains("let x: Array<Int> = []"))
        XCTAssertTrue(out.contains("<b>not bold</b>"))
        XCTAssertTrue(out.hasSuffix("**bold**"))
    }

    func testEntitiesAreDecoded() {
        XCTAssertEqual(CommentHTML.markdown(from: "<p>a &lt; b &amp;&amp; c &gt; d</p>"), "a < b && c > d")
    }
}
