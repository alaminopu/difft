import XCTest
import AppKit
@testable import DifftUI

final class CodeFontTests: XCTestCase {
    func testEmptyFamilyResolvesToSystemMonospace() {
        let font = CodeFont.resolve(family: CodeFont.systemFamily, size: 13)
        XCTAssertEqual(font.pointSize, 13)
        XCTAssertTrue(font.isFixedPitch)
    }

    /// Uninstalling a font must not leave the diff unrenderable.
    func testUnknownFamilyFallsBackInsteadOfFailing() {
        let font = CodeFont.resolve(family: "No Such Font 12345", size: 11)
        XCTAssertEqual(font.pointSize, 11)
        XCTAssertTrue(font.isFixedPitch)
    }

    func testKnownFamilyIsHonoured() throws {
        // Menlo ships with macOS; skip rather than fail if it ever does not.
        try XCTSkipIf(NSFont(name: "Menlo", size: 12) == nil, "Menlo not installed")
        let font = CodeFont.resolve(family: "Menlo", size: 15)
        XCTAssertEqual(font.familyName, "Menlo")
        XCTAssertEqual(font.pointSize, 15)
    }

    func testInstalledFamiliesAreAllMonospaced() {
        let families = CodeFont.installedFamilies()
        XCTAssertFalse(families.isEmpty, "a Mac always has some monospaced font")
        for family in families {
            XCTAssertEqual(NSFont(name: family, size: 12)?.isFixedPitch, true,
                           "\(family) is not fixed pitch")
        }
        XCTAssertEqual(families, families.sorted())
    }

    /// SF Mono has no public family name, so it must not be expected in the
    /// enumerated list — it is offered separately as the default.
    func testSystemFamilySentinelIsNotAnInstalledFamily() {
        XCTAssertFalse(CodeFont.installedFamilies().contains(CodeFont.systemFamily))
    }
}
