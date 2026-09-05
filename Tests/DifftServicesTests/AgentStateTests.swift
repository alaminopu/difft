import XCTest
@testable import DifftServices

final class AgentStateTests: XCTestCase {
    func testAfterFailureWithoutCancelReportsFailed() {
        let result = AgentState.afterFailure(userCancelled: false, message: "boom")
        XCTAssertEqual(result, .failed("boom"))
    }

    func testAfterFailureWithUserCancelStaysIdle() {
        let result = AgentState.afterFailure(userCancelled: true, message: "claude exited 143")
        XCTAssertEqual(result, .idle)
    }

    // `.failed` must not be a dead end: a new run has to be startable from it
    // (a fresh run resets state), so Ask/Review/Verify can be retried after a
    // failure instead of being permanently disabled until the PR is reopened.
    func testCanStartFromIdle() {
        XCTAssertTrue(AgentState.idle.canStart)
    }

    func testCanStartFromFailed() {
        XCTAssertTrue(AgentState.failed("boom").canStart)
    }

    func testCannotStartWhileRunning() {
        XCTAssertFalse(AgentState.running("Reviewing").canStart)
    }
}
