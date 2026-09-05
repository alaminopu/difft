import XCTest
@testable import DifftServices

final class FakeStreamingRunner: StreamingProcessRunning, @unchecked Sendable {
    var lines: [String] = []
    var cancelled = false
    var lastArguments: [String] = []
    func stream(_ executable: String, arguments: [String], currentDirectory: URL?) -> AsyncThrowingStream<String, Error> {
        lastArguments = arguments
        let toYield = lines
        return AsyncThrowingStream { cont in
            for l in toYield { cont.yield(l) }
            cont.finish()
        }
    }
    func cancel() { cancelled = true }
}

final class AgentServiceTests: XCTestCase {
    let pr = PullRequest(number: 1, title: "t", body: "b", headRefName: "h", authorLogin: "a")

    func testMapsLinesToEvents() async throws {
        let fake = FakeStreamingRunner()
        fake.lines = [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#,
            "",
            #"{"type":"result","is_error":false,"result":"done"}"#,
        ]
        let svc = AgentService(runner: fake)
        var events: [AgentEvent] = []
        for try await e in svc.run(.clarify(pr: pr, selection: nil, question: "q", history: []), in: URL(fileURLWithPath: "/tmp")) {
            events.append(e)
        }
        XCTAssertEqual(events, [.textDelta("hi"), .result(isError: false, text: "done")])
        XCTAssertEqual(fake.lastArguments.first, "-p")
    }

    func testCancelForwards() {
        let fake = FakeStreamingRunner()
        let svc = AgentService(runner: fake)
        svc.cancel()
        XCTAssertTrue(fake.cancelled)
    }
}
