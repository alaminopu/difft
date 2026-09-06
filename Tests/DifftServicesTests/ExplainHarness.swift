import XCTest
@testable import DifftServices

/// Dev harness, not a unit test: renders the explain prompt or parses a real
/// agent transcript when the matching env var is set, and does nothing
/// otherwise. Keeps the live end-to-end check reproducible.
final class ExplainHarnessTests: XCTestCase {
    func testRenderPromptWhenAsked() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["DIFFT_DUMP_PROMPT"] else { return }
        let pr = PullRequest(number: Int(env["P_NUM"] ?? "1") ?? 1,
                             title: env["P_TITLE"] ?? "", body: env["P_BODY"] ?? "",
                             headRefName: env["P_HEAD"] ?? "main", authorLogin: env["P_AUTHOR"] ?? "")
        try Data(AgentTask.explain(pr: pr, diffSummary: env["P_FILES"] ?? "").prompt.utf8)
            .write(to: URL(fileURLWithPath: out))
    }

    func testParseTranscriptWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["DIFFT_PARSE_TRANSCRIPT"] else { return }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let e = try XCTUnwrap(ExplanationParser.parse(text), "live transcript did not parse")
        XCTAssertFalse(e.summary.isEmpty)
        XCTAssertFalse(e.areas.isEmpty)
        print("PARSED areas=\(e.areas.count) risks=\(e.risks.count) outOfScope=\(e.outOfScope.count)")
        for a in e.areas { print("  area: \(a.title) files=\(a.files.count) anchors=\(a.anchors.count)") }
        for a in e.areas.flatMap(\.anchors) { print("  anchor: \(a.file):\(a.line.map(String.init) ?? "-")") }
    }
}
