import XCTest
@testable import PaseoComputerUseCore

/// The stop key and the click and scroll log follow the agent's control.
/// Fakes stand in for both taps, so no live tap is created.
@MainActor
final class ControlInputWatchTests: XCTestCase {
    private final class FakeStopKey: StopKeyWatch {
        var canArm = true
        private(set) var armed = false
        private(set) var arms = 0
        private(set) var disarms = 0

        func arm() -> Bool {
            arms += 1
            if canArm { armed = true }
            return armed
        }

        func disarm() {
            disarms += 1
            armed = false
        }
    }

    private final class FakeInputLog: PointerInputWatch {
        private(set) var running = false
        private(set) var starts = 0
        private(set) var stops = 0

        func start() {
            starts += 1
            running = true
        }

        func stop() {
            stops += 1
            running = false
        }
    }

    private var stopKey: FakeStopKey!
    private var inputLog: FakeInputLog!
    private var watch: ControlInputWatch!

    override func setUp() async throws {
        stopKey = FakeStopKey()
        inputLog = FakeInputLog()
        watch = ControlInputWatch(stopKey: stopKey, inputLog: inputLog)
    }

    func testNothingRunsBeforeAnAgentTakesControl() {
        XCTAssertFalse(stopKey.armed)
        XCTAssertFalse(inputLog.running)
        XCTAssertEqual(inputLog.starts, 0)
    }

    func testTakingControlStartsTheLog() {
        XCTAssertTrue(watch.arm())
        XCTAssertTrue(stopKey.armed)
        XCTAssertTrue(inputLog.running)
    }

    func testTheLogDoesNotStartWhenTheStopKeyCannotArm() {
        stopKey.canArm = false
        XCTAssertFalse(watch.arm())
        XCTAssertFalse(inputLog.running)
        XCTAssertEqual(inputLog.starts, 0)
    }

    func testReleasingControlStopsTheLog() {
        XCTAssertTrue(watch.arm())
        watch.disarm()
        XCTAssertFalse(stopKey.armed)
        XCTAssertFalse(inputLog.running)
    }

    func testEscapeOrAShakeStopsTheLogAtOnce() {
        XCTAssertTrue(watch.arm())
        watch.userStopped()
        XCTAssertFalse(inputLog.running)
        // The plugin releases control next; the stop key stays armed until then.
        XCTAssertTrue(stopKey.armed)
    }

    func testTakingControlAgainStartsTheLogAgain() {
        XCTAssertTrue(watch.arm())
        watch.userStopped()
        XCTAssertTrue(watch.arm())
        XCTAssertTrue(inputLog.running)
        watch.disarm()
        XCTAssertTrue(watch.arm())
        XCTAssertTrue(inputLog.running)
    }
}
