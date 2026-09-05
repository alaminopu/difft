import XCTest
@testable import DifftServices

final class FindingsParserTests: XCTestCase {
    func testParsesFencedJSON() {
        let text = """
        Here is my review.
        ```json
        [{"severity": "high", "file": "a.swift", "line": 10, "explanation": "force unwrap"}]
        ```
        Done.
        """
        XCTAssertEqual(FindingsParser.parse(text),
                       [Finding(severity: "high", file: "a.swift", line: 10, explanation: "force unwrap")])
    }

    func testParsesBareJSON() {
        let text = #"[{"severity": "low", "file": "b.py", "line": 2, "explanation": "nit"}]"#
        XCTAssertEqual(FindingsParser.parse(text).count, 1)
    }

    func testMalformedReturnsEmpty() {
        XCTAssertEqual(FindingsParser.parse("no json here"), [])
        XCTAssertEqual(FindingsParser.parse("```json\nbroken\n```"), [])
    }
}
