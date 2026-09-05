import XCTest
@testable import DifftServices

final class StreamJSONParserTests: XCTestCase {
    func testAssistantText() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#
        XCTAssertEqual(StreamJSONParser.event(fromLine: line), .textDelta("Hello"))
    }

    func testToolUse() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{}}]}}"#
        XCTAssertEqual(StreamJSONParser.event(fromLine: line), .toolUse(name: "Bash", detail: nil))
    }

    func testToolUseCarriesInputDetail() {
        let bash = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"npm run dev","description":"Start dev server"}}]}}"#
        XCTAssertEqual(StreamJSONParser.event(fromLine: bash),
                       .toolUse(name: "Bash", detail: "Start dev server"))

        let bashNoDesc = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"pytest -q"}}]}}"#
        XCTAssertEqual(StreamJSONParser.event(fromLine: bashNoDesc),
                       .toolUse(name: "Bash", detail: "pytest -q"))

        let read = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","id":"t2","input":{"file_path":"/tmp/a.py"}}]}}"#
        XCTAssertEqual(StreamJSONParser.event(fromLine: read),
                       .toolUse(name: "Read", detail: "/tmp/a.py"))

        let grep = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","id":"t3","input":{"pattern":"def main"}}]}}"#
        XCTAssertEqual(StreamJSONParser.event(fromLine: grep),
                       .toolUse(name: "Grep", detail: "def main"))
    }

    func testResultSuccess() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"All good"}"#
        XCTAssertEqual(StreamJSONParser.event(fromLine: line), .result(isError: false, text: "All good"))
    }

    func testResultError() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}"#
        XCTAssertEqual(StreamJSONParser.event(fromLine: line), .result(isError: true, text: "boom"))
    }

    func testBlankLineNil() {
        XCTAssertNil(StreamJSONParser.event(fromLine: "  "))
    }

    func testGarbageIsUnknown() {
        XCTAssertEqual(StreamJSONParser.event(fromLine: "not json"), .unknown("not json"))
    }

    func testSystemInitIsUnknown() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc"}"#
        XCTAssertEqual(StreamJSONParser.event(fromLine: line), .unknown(line))
    }
}
