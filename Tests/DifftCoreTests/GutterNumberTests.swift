import XCTest
@testable import DifftCore

final class GutterNumberTests: XCTestCase {
    func testContextLineShowsMatchingSideNumber() {
        let context = DiffLine(kind: .context, oldNumber: 5, newNumber: 7, text: "x")
        XCTAssertEqual(context.gutterNumber(for: .left), 5)
        XCTAssertEqual(context.gutterNumber(for: .right), 7)
        XCTAssertEqual(context.gutterNumber(for: .unified), 5)
    }

    func testAdditionOnlyHasRightNumber() {
        let addition = DiffLine(kind: .addition, oldNumber: nil, newNumber: 9, text: "y")
        XCTAssertNil(addition.gutterNumber(for: .left))
        XCTAssertEqual(addition.gutterNumber(for: .right), 9)
        XCTAssertEqual(addition.gutterNumber(for: .unified), 9)
    }

    func testDeletionOnlyHasLeftNumber() {
        let deletion = DiffLine(kind: .deletion, oldNumber: 3, newNumber: nil, text: "z")
        XCTAssertEqual(deletion.gutterNumber(for: .left), 3)
        XCTAssertNil(deletion.gutterNumber(for: .right))
        XCTAssertEqual(deletion.gutterNumber(for: .unified), 3)
    }
}
