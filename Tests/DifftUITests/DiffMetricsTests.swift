import XCTest
@testable import DifftUI

final class DiffMetricsTests: XCTestCase {
    func testDigitsForLineCount() {
        XCTAssertEqual(DiffMetrics.digits(for: 1), 2, "never narrower than two digits")
        XCTAssertEqual(DiffMetrics.digits(for: 9), 2)
        XCTAssertEqual(DiffMetrics.digits(for: 99), 2)
        XCTAssertEqual(DiffMetrics.digits(for: 100), 3)
        XCTAssertEqual(DiffMetrics.digits(for: 12345), 5)
    }

    func testDigitsHandlesEmptyFile() {
        XCTAssertEqual(DiffMetrics.digits(for: 0), 2)
    }

    /// The bug this replaces: a fixed 44pt gutter while the number font scaled
    /// with the stepper, so large sizes overflowed and wrapped the row.
    func testGutterGrowsWithFontSize() {
        let small = DiffMetrics(fontSize: 9, digits: 5, unified: false)
        let large = DiffMetrics(fontSize: 18, digits: 5, unified: false)
        XCTAssertGreaterThan(large.gutterWidth, small.gutterWidth)
    }

    func testGutterGrowsWithDigits() {
        let few = DiffMetrics(fontSize: 12, digits: 2, unified: false)
        let many = DiffMetrics(fontSize: 12, digits: 6, unified: false)
        XCTAssertGreaterThan(many.gutterWidth, few.gutterWidth)
    }

    /// Unified shows both numbers in one column, so it needs roughly twice
    /// the width for the same file.
    func testUnifiedGutterIsWiderThanSideBySide() {
        let side = DiffMetrics(fontSize: 12, digits: 4, unified: false)
        let unified = DiffMetrics(fontSize: 12, digits: 4, unified: true)
        XCTAssertGreaterThan(unified.gutterWidth, side.gutterWidth * 1.5)
    }

    /// A 5-digit number at the largest size must actually fit — this is the
    /// exact case that used to wrap.
    func testWidestNumberFitsAtLargestFontSize() {
        let m = DiffMetrics(fontSize: 18, digits: 5, unified: false)
        let needed = CGFloat(5) * (18 - 1) * 0.62
        XCTAssertGreaterThanOrEqual(m.gutterWidth, needed)
    }

    func testTotalGutterIsTheSumOfItsParts() {
        let m = DiffMetrics(fontSize: 12, digits: 3, unified: false)
        XCTAssertEqual(m.totalGutter, m.gutterWidth + m.gutterTrailing + m.separatorWidth)
    }

    func testFontSizeBoundsBracketTheDefault() {
        XCTAssertLessThan(DiffMetrics.minFontSize, DiffMetrics.defaultFontSize)
        XCTAssertLessThan(DiffMetrics.defaultFontSize, DiffMetrics.maxFontSize)
    }

    /// The unified gutter reserves room for `digits * 2 + 1` characters, so
    /// the string it renders must never be longer than that. It used to pad
    /// to a hardcoded 5 regardless, which overflowed every file whose line
    /// numbers were shorter and truncated the new-line column away.
    func testUnifiedGutterTextFitsTheReservedWidth() {
        for digits in 2...7 {
            let maxLine = Int(pow(10.0, Double(digits))) - 1
            let text = HalfLineView.unifiedGutterText(old: maxLine, new: maxLine, digits: digits)
            XCTAssertEqual(text.count, digits * 2 + 1,
                           "digits=\(digits) must fit the width DiffMetrics reserves")
        }
    }

    /// Fields stay column-aligned whatever each number's own width is.
    func testUnifiedGutterTextRightAlignsBothFields() {
        XCTAssertEqual(HalfLineView.unifiedGutterText(old: 7, new: 1234, digits: 4), "   7 1234")
        XCTAssertEqual(HalfLineView.unifiedGutterText(old: nil, new: 42, digits: 4), "       42")
        XCTAssertEqual(HalfLineView.unifiedGutterText(old: 42, new: nil, digits: 4), "  42     ")
    }

    /// A number wider than the file's digit count must not shift the field
    /// beside it — the old padding silently allowed that.
    func testUnifiedGutterTextWidthMatchesMetrics() {
        let m = DiffMetrics(fontSize: 12, digits: 3, unified: true)
        XCTAssertEqual(m.digits, 3)
        let text = HalfLineView.unifiedGutterText(old: 999, new: 999, digits: m.digits)
        XCTAssertEqual(text.count, m.digits * 2 + 1)
    }
}
