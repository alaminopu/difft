import XCTest
@testable import DifftServices
@testable import DifftCore

final class ReportBuilderTests: XCTestCase {
    private func input() -> ReportInput {
        let pr = PullRequest(number: 3, title: "T <script>", body: "B", headRefName: "h", authorLogin: "a")
        let session = SessionData(pr: pr, repoDir: "/tmp/myrepo", viewedFiles: ["a.txt"],
            chat: [ChatMessage(role: "user", text: "q1", contextChip: "a.txt:1-2"),
                   ChatMessage(role: "assistant", text: "a1", contextChip: nil)],
            findings: [Finding(severity: "low", file: "a.txt", line: 1, explanation: "nit"),
                       Finding(severity: "high", file: "a.txt", line: 2, explanation: "bug & bad")],
            verdict: "pass")
        let files = [FileDiff(path: "a.txt", kind: .modified,
                              hunks: [Hunk(header: "@@ -1 +1 @@", lines: [DiffLine(kind: .addition, oldNumber: nil, newNumber: 1, text: "hi")])])]
        return ReportInput(session: session, files: files, screenshots: [("before.png", Data([0x89, 0x50]))])
    }

    func testContainsCoreSections() {
        let html = ReportBuilder.html(for: input())
        XCTAssertTrue(html.contains("PR #3"))
        XCTAssertTrue(html.contains("pass"))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("q1"))
        XCTAssertTrue(html.contains("<details>"))
    }

    func testEscapesHTML() {
        let html = ReportBuilder.html(for: input())
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("bug &amp; bad"))
    }

    func testFindingsSortedBySeverity() {
        let html = ReportBuilder.html(for: input())
        let highPos = html.range(of: "bug &amp; bad")!.lowerBound
        let lowPos = html.range(of: "nit")!.lowerBound
        XCTAssertLessThan(highPos, lowPos)
    }

    func testDefaultURLShape() {
        let url = ReportBuilder.defaultURL(repoName: "myrepo", prNumber: 3, date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(url.path.contains("Difft-reports"))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("myrepo-pr3-1970-01-01"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".html"))
    }

    func testAttributeContextSafety() {
        let pr = PullRequest(number: 1, title: "safe", body: "B", headRefName: "h", authorLogin: "a")
        let session = SessionData(pr: pr, repoDir: "/tmp/myrepo", viewedFiles: [],
            chat: [],
            findings: [Finding(severity: "high\" onmouseover=\"alert('xss)", file: "a.txt", line: 1, explanation: "test")],
            verdict: "pass\" onclick=\"bad")
        let files = [FileDiff(path: "a.txt", kind: .modified, hunks: [])]
        let html = ReportBuilder.html(for: ReportInput(session: session, files: files, screenshots: []))
        XCTAssertFalse(html.contains("\" onclick"))
        XCTAssertFalse(html.contains("\" onmouseover"))
        XCTAssertTrue(html.contains("&quot;"))
    }
}
