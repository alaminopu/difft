import XCTest
@testable import DifftServices

final class AgentTaskTests: XCTestCase {
    let pr = PullRequest(number: 5, title: "Add login", body: "Adds login page", headRefName: "feat/login", authorLogin: "bob")

    func testClarifyPromptContainsAllContext() {
        let task = AgentTask.clarify(pr: pr, selection: "src/a.swift:10-12\n+let x = 1",
                                     question: "why x?",
                                     history: [ChatMessage(role: "user", text: "earlier q", contextChip: nil)])
        let p = task.prompt
        XCTAssertTrue(p.contains("Add login"))
        XCTAssertTrue(p.contains("src/a.swift:10-12"))
        XCTAssertTrue(p.contains("why x?"))
        XCTAssertTrue(p.contains("earlier q"))
    }

    func testClarifyArgsAreReadOnly() {
        let task = AgentTask.clarify(pr: pr, selection: nil, question: "q", history: [])
        let args = task.cliArguments
        XCTAssertEqual(args.first, "-p")
        XCTAssertTrue(args.contains("--allowedTools"))
        XCTAssertTrue(args.contains("Read,Grep,Glob"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
    }

    func testReviewPromptAsksForJSONFindings() {
        let task = AgentTask.review(pr: pr, diffSummary: "3 files changed")
        XCTAssertTrue(task.prompt.contains("json"))
        XCTAssertTrue(task.prompt.contains("severity"))
        XCTAssertTrue(task.cliArguments.contains("Read,Grep,Glob"))
    }

    func testFixPromptAndTools() {
        let finding = Finding(severity: "medium", file: "a/b.py", line: 42,
                              explanation: "Throttle slots leak on the error path")
        let task = AgentTask.fix(pr: pr, finding: finding)
        let p = task.prompt
        XCTAssertTrue(p.contains("a/b.py:42"))
        XCTAssertTrue(p.contains("Throttle slots leak"))
        XCTAssertTrue(p.contains("Do not commit"))

        let args = task.cliArguments
        XCTAssertTrue(args.contains("Read,Grep,Glob,Edit,Write"))
        // Edits only: no shell, and never the permission bypass.
        XCTAssertFalse(args.joined().contains("Bash"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
    }

    /// The explain task's whole value is that it does not recite the diff
    /// file by file and does not answer in prose.
    func testExplainPromptAsksForGroupedJSON() {
        let task = AgentTask.explain(pr: pr, diffSummary: "a.swift (+3/−1)")
        XCTAssertTrue(task.prompt.contains("Add login"))
        XCTAssertTrue(task.prompt.contains("a.swift (+3/−1)"))
        XCTAssertTrue(task.prompt.contains("```json"))
        XCTAssertTrue(task.prompt.contains("outOfScope"))
        XCTAssertTrue(task.prompt.contains("BEHAVIOUR or CONCERN"),
                      "must group by behaviour, not by file")
        // The reviewer-lineage ideas the skill survey converged on.
        XCTAssertTrue(task.prompt.contains("load-bearing"))
        XCTAssertTrue(task.prompt.contains("mechanical"))
        XCTAssertTrue(task.prompt.contains("motivationInferred"))
        XCTAssertTrue(task.prompt.contains("readFirst"))
        XCTAssertTrue(task.prompt.contains("not a code review"),
                      "must not duplicate the Findings reviewer")
        // Read-only, like clarify and review — explaining never edits or runs.
        XCTAssertTrue(task.cliArguments.contains("Read,Grep,Glob"))
        XCTAssertFalse(task.cliArguments.contains("--dangerously-skip-permissions"))
    }

}
