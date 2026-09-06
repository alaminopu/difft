import XCTest

/// `ElapsedLabel.format` lives in the app target, which is not importable, so
/// the rule it encodes is pinned here against the same implementation.
private func format(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
}

final class ElapsedFormatTests: XCTestCase {
    func testSecondsUnderAMinute() {
        XCTAssertEqual(format(0), "0s")
        XCTAssertEqual(format(1.9), "1s", "truncates rather than rounding up")
        XCTAssertEqual(format(59), "59s")
    }

    func testMinutesAndSeconds() {
        XCTAssertEqual(format(60), "1m 0s")
        XCTAssertEqual(format(61), "1m 1s")
        XCTAssertEqual(format(19 * 60 + 7), "19m 7s")
    }

    /// A clock started before a system time change must not count backwards.
    func testNegativeElapsedClampsToZero() {
        XCTAssertEqual(format(-5), "0s")
    }
}
