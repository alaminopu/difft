import XCTest
@testable import DifftServices

final class ProcessRunnerTests: XCTestCase {
    /// A diff of a Latin-1 file holds bytes that are not UTF-8. Decoding the
    /// output strictly turned the whole thing into "", and the PR showed no
    /// files and no error.
    func testOutputWithInvalidUTF8KeepsEverythingElse() async throws {
        let r = try await DefaultProcessRunner().run(
            "printf", arguments: ["+caf\\351\\n+ok\\n"], currentDirectory: nil)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "+caf\u{FFFD}\n+ok\n")
    }
}
