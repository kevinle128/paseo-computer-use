import CoreFoundation
import XCTest
@testable import PaseoComputerUseCore

final class ElementSignatureTests: XCTestCase {
    private func button(
        name: String? = "Save",
        role: String = "AXButton",
        subrole: String? = nil,
        frame: AXBoundsSnapshot? = AXBoundsSnapshot(x: 10, y: 20, width: 80, height: 24)
    ) -> ElementSignature {
        ElementSignature(role: role, subrole: subrole, name: name, frame: frame)
    }

    func testIdenticalSignaturesMatch() {
        XCTAssertTrue(button().matches(button()))
    }

    func testSubPointFrameDriftStillMatches() {
        let live = button(frame: AXBoundsSnapshot(x: 11, y: 20.5, width: 80, height: 23))
        XCTAssertTrue(button().matches(live))
    }

    func testMovedElementDoesNotMatch() {
        let live = button(frame: AXBoundsSnapshot(x: 200, y: 20, width: 80, height: 24))
        XCTAssertFalse(button().matches(live))
    }

    func testRenamedElementDoesNotMatch() {
        XCTAssertFalse(button().matches(button(name: "Delete")))
    }

    func testDifferentRoleOrSubroleDoesNotMatch() {
        XCTAssertFalse(button().matches(button(role: "AXCheckBox")))
        XCTAssertFalse(button().matches(button(subrole: "AXCloseButton")))
    }

    func testFrameAppearingOrDisappearingDoesNotMatch() {
        XCTAssertFalse(button().matches(button(frame: nil)))
        XCTAssertFalse(button(frame: nil).matches(button()))
        XCTAssertTrue(button(frame: nil).matches(button(frame: nil)))
    }

    func testEmptyNameAndSubroleEqualAbsentOnes() {
        XCTAssertTrue(button(name: nil).matches(button(name: "")))
        XCTAssertTrue(button(subrole: "").matches(button(subrole: nil)))
    }

    func testParsesTheSignatureThePluginSends() {
        let sent: [String: Any] = [
            "role": "AXButton",
            "name": "Save",
            "frame": ["x": NSNumber(value: 10), "y": NSNumber(value: 20), "width": NSNumber(value: 80.0), "height": NSNumber(value: 24)],
        ]
        XCTAssertEqual(ElementSignature(dictionary: sent), button())
        XCTAssertEqual(
            ElementSignature(dictionary: ["role": "AXButton", "subrole": "AXCloseButton"]),
            button(name: nil, subrole: "AXCloseButton", frame: nil)
        )
    }

    func testRejectsAMissingOrMalformedSignature() {
        XCTAssertNil(ElementSignature(dictionary: nil))
        XCTAssertNil(ElementSignature(dictionary: ["name": "Save"]))
        XCTAssertNil(ElementSignature(dictionary: ["role": ""]))
        XCTAssertNil(ElementSignature(dictionary: ["role": "AXButton", "frame": ["x": NSNumber(value: 1)]]))
    }

    func testAnotherAgentsViewDoesNotMatchTheElementNowAtThatPath() {
        // Agent A saw "Open" at a path; after a row was inserted, "New" sits
        // there. A's signature must not match the element now at that path.
        let seenByA = ElementSignature(dictionary: [
            "role": "AXButton",
            "name": "Open",
            "frame": ["x": NSNumber(value: 10), "y": NSNumber(value: 10), "width": NSNumber(value: 60), "height": NSNumber(value: 20)],
        ])
        let liveAtPath = ElementSignature(
            role: "AXButton",
            subrole: nil,
            name: "New",
            frame: AXBoundsSnapshot(x: 10, y: 10, width: 60, height: 20)
        )
        XCTAssertEqual(seenByA?.matches(liveAtPath), false)
    }

    func testNativeIdCarriesOwnerPid() {
        let id = ElementNativeId.make(pid: 4242, path: [0, 3, 1])
        XCTAssertEqual(id, "4242:0.3.1")
        XCTAssertEqual(ElementNativeId.ownerPid(of: id), 4242)
        XCTAssertEqual(ElementNativeId.make(pid: 7, path: []), "7:")
        XCTAssertNil(ElementNativeId.ownerPid(of: "ax_12"))
    }

    private func state(_ verification: [String: Any]) -> String? {
        verification["state"] as? String
    }

    private func reason(_ verification: [String: Any]) -> String? {
        verification["reason"] as? String
    }

    func testTextEntryVerifiedOnlyWhenFieldChangedAndContainsText() {
        XCTAssertEqual(state(ActionVerification.textEntry(before: "", after: "xin chao", entered: "xin chao")), "verified")
        XCTAssertEqual(state(ActionVerification.textEntry(before: nil, after: "a xin chao", entered: "xin chao")), "verified")
    }

    func testTextEntryUnverifiedWhenInputMethodRewroteText() {
        let result = ActionVerification.textEntry(before: "", after: "xin chào", entered: "xin chao")
        XCTAssertEqual(state(result), "unverified")
        XCTAssertEqual(reason(result), "field value does not contain the entered text")
    }

    func testTextEntryUnverifiedWhenFieldUnchangedOrUnreadable() {
        XCTAssertEqual(reason(ActionVerification.textEntry(before: "hi", after: "hi", entered: "hi")), "field value did not change")
        XCTAssertEqual(state(ActionVerification.textEntry(before: "", after: nil, entered: "hi")), "unverified")
    }

    func testSetValueVerifiedOnlyOnExactReadBack() {
        XCTAssertEqual(state(ActionVerification.setValue(requested: "https://a.b", readBack: "https://a.b")), "verified")
        XCTAssertEqual(state(ActionVerification.setValue(requested: "https://a.b", readBack: "")), "unverified")
        XCTAssertEqual(state(ActionVerification.setValue(requested: "x", readBack: nil)), "unverified")
    }

    func testSelectionVerifiedOnlyOnMatchingRange() {
        let requested = CFRange(location: 3, length: 4)
        XCTAssertEqual(state(ActionVerification.selection(requested: requested, readBack: CFRange(location: 3, length: 4))), "verified")
        XCTAssertEqual(state(ActionVerification.selection(requested: requested, readBack: CFRange(location: 0, length: 9))), "unverified")
        XCTAssertEqual(state(ActionVerification.selection(requested: requested, readBack: nil)), "unverified")
    }
}
