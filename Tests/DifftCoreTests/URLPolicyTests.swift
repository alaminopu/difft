import XCTest
@testable import DifftCore

final class URLPolicyTests: XCTestCase {
    private func allows(_ s: String) -> Bool {
        guard let url = URL(string: s) else { return false }
        return DifftURLPolicy.allowsOpening(url)
    }

    func testWebLinksAreOpened() {
        XCTAssertTrue(allows("https://github.com/o/r/pull/1"))
        XCTAssertTrue(allows("http://example.com"))
        XCTAssertTrue(allows("mailto:someone@example.com"))
        XCTAssertTrue(allows("HTTPS://example.com"), "scheme match is case-insensitive")
    }

    /// A PR description or review comment on a fork is attacker-controlled
    /// markdown. Handing one of these to LaunchServices opens whatever is
    /// registered for the scheme.
    func testEverythingElseIsInert() {
        XCTAssertFalse(allows("file:///Applications/Calculator.app"))
        XCTAssertFalse(allows("javascript:alert(1)"))
        XCTAssertFalse(allows("x-apple-shortcuts://run-shortcut?name=x"))
        XCTAssertFalse(allows("ssh://host/-oProxyCommand=x"))
        XCTAssertFalse(allows("data:text/html,<script>x</script>"))
        XCTAssertFalse(allows("ftp://example.com"))
    }

    func testSchemelessIsInert() {
        XCTAssertFalse(allows("/etc/passwd"))
        XCTAssertFalse(allows("example.com"))
    }

    /// The app's own scheme is handled before the policy is consulted, but it
    /// must not be openable by the system either.
    func testTheAppsOwnSchemeIsNotHandedToTheSystem() {
        XCTAssertFalse(allows("difft-commit://a1b2c3d"))
    }
}
