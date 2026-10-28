import XCTest
@testable import PaseoComputerUseCore

final class MenuItemMarkTests: XCTestCase {
    func testCheckMarkMeansChecked() {
        XCTAssertEqual(MenuItemMark.state(for: "✓"), "checked")
        XCTAssertEqual(MenuItemMark.state(for: "✔︎"), "checked")
    }

    func testRadioMarksMeanChecked() {
        XCTAssertEqual(MenuItemMark.state(for: "•"), "checked")
        XCTAssertEqual(MenuItemMark.state(for: "◆"), "checked")
    }

    func testDashMeansMixed() {
        XCTAssertEqual(MenuItemMark.state(for: "-"), "mixed")
        XCTAssertEqual(MenuItemMark.state(for: "–"), "mixed")
        XCTAssertEqual(MenuItemMark.state(for: " − "), "mixed")
    }

    func testNoMarkMeansNoState() {
        XCTAssertNil(MenuItemMark.state(for: nil))
        XCTAssertNil(MenuItemMark.state(for: ""))
        XCTAssertNil(MenuItemMark.state(for: "  "))
    }
}
