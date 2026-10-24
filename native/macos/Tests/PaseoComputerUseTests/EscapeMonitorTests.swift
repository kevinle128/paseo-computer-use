import XCTest
@testable import PaseoComputerUseCore

final class EscapeMonitorTests: XCTestCase {
    func testOnlyTheFirstKeyDownOfAnEscapePressAborts() {
        XCTAssertTrue(UserInputEscapeMonitor.isNewEscapePress(keyCode: 53, autorepeat: 0))
        // Key repeat while Escape is held down.
        XCTAssertFalse(UserInputEscapeMonitor.isNewEscapePress(keyCode: 53, autorepeat: 1))
    }

    func testOtherKeysNeverAbort() {
        XCTAssertFalse(UserInputEscapeMonitor.isNewEscapePress(keyCode: 0, autorepeat: 0))
    }

    func testOnlyHardwarePointerMotionCountsAsATakeover() {
        // The mouse and trackpad post with no source process.
        XCTAssertTrue(UserInputEscapeMonitor.isHardwarePointerEvent(sourcePid: 0))
        // Another process (an automation tool) moving the pointer is not the user.
        XCTAssertFalse(UserInputEscapeMonitor.isHardwarePointerEvent(sourcePid: 4242))
    }

    func testSyntheticEventsUseAPrivateSourceThatCannotMoveThePointer() throws {
        let source = try XCTUnwrap(InputDriver.syntheticEventSource())
        // A private source gets its own state id, never the shared ones.
        XCTAssertNotEqual(source.sourceStateID, .hidSystemState)
        XCTAssertNotEqual(source.sourceStateID, .combinedSessionState)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertNotEqual(event.getIntegerValueField(.eventSourceStateID), Int64(CGEventSourceStateID.hidSystemState.rawValue))
    }
}
