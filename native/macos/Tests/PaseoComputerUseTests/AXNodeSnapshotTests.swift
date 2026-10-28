import XCTest
@testable import PaseoComputerUseCore

final class AXNodeSnapshotTests: XCTestCase {
    private func menuBarItem(selected: Bool?) -> AXNodeSnapshot {
        AXNodeSnapshot(
            nativeId: "1:0.0",
            role: "AXMenuBarItem",
            subrole: nil,
            name: "Edit",
            nodeDescription: nil,
            value: nil,
            bounds: nil,
            states: ["enabled"],
            selected: selected,
            actions: [],
            children: []
        )
    }

    func testSelectedFalseIsSentSoItDiffersFromAnAttributeThatIsNotReported() {
        XCTAssertEqual(menuBarItem(selected: false).toDictionary()["selected"] as? Bool, false)
        XCTAssertEqual(menuBarItem(selected: true).toDictionary()["selected"] as? Bool, true)
        XCTAssertNil(menuBarItem(selected: nil).toDictionary()["selected"])
    }

    func testAWindowNodeCarriesItsWindowServerId() {
        let node = AXNodeSnapshot(
            nativeId: "1:0", role: "AXWindow", subrole: nil, name: "Canvas", nodeDescription: nil, value: nil,
            bounds: nil, states: [], selected: nil, actions: [], children: [], windowId: 38214
        )
        XCTAssertEqual(node.toDictionary()["window_id"] as? Int, 38214)
        let other = AXNodeSnapshot(
            nativeId: "1:1", role: "AXButton", subrole: nil, name: nil, nodeDescription: nil, value: nil,
            bounds: nil, states: [], selected: nil, actions: [], children: []
        )
        XCTAssertNil(other.toDictionary()["window_id"])
    }
}
