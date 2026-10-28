import CoreGraphics
import XCTest
@testable import PaseoComputerUseCore

/// Drives the log's records directly. The live tap and the workspace
/// observer are never started here.
final class UserInputLogTests: XCTestCase {
    func testPointerRecordsArePrunedByAge() {
        let log = UserInputLog()
        log.pointerTapEnabled(at: 0)
        log.recordPointer(at: CGPoint(x: 1, y: 1), uptime: 10)
        log.recordPointer(at: CGPoint(x: 2, y: 2), uptime: 12)
        log.recordPointer(at: CGPoint(x: 3, y: 3), uptime: 12 + UserInputLog.retentionSeconds + 0.5)
        XCTAssertEqual(log.snapshot().pointerInputs.map(\.location), [CGPoint(x: 3, y: 3)])
    }

    func testAScrollAtOnePlaceIsOneRecordWithTheLatestTime() {
        let log = UserInputLog()
        log.pointerTapEnabled(at: 0)
        for step in 0..<100 {
            log.recordPointer(at: CGPoint(x: 5, y: 5), uptime: 10 + Double(step) * 0.01)
        }
        let records = log.snapshot().pointerInputs
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.uptime ?? 0, 10.99, accuracy: 1e-9)
    }

    func testDroppingARecordMovesTheCoverageStart() {
        let log = UserInputLog()
        log.pointerTapEnabled(at: 0)
        for step in 0...UserInputLog.maxPointerInputs {
            log.recordPointer(at: CGPoint(x: Double(step), y: 0), uptime: 10 + Double(step) * 0.001)
        }
        let snapshot = log.snapshot()
        XCTAssertEqual(snapshot.pointerInputs.count, UserInputLog.maxPointerInputs)
        XCTAssertEqual(snapshot.pointerLogSince ?? 0, 10, accuracy: 1e-9)
    }

    func testARecordKeepsTheWindowsAtItsPlaceAndTheListIsReadAtMostOncePerReuseTime() {
        let target = UserActivity.ScreenWindow(pid: 100, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let other = UserActivity.ScreenWindow(pid: 200, bounds: CGRect(x: 200, y: 0, width: 100, height: 100))
        var reads = 0
        var screen = [target, other]
        let log = UserInputLog(readWindows: {
            reads += 1
            return screen
        })
        XCTAssertEqual(log.windows(at: CGPoint(x: 10, y: 10), uptime: 10), [target])
        XCTAssertEqual(log.windows(at: CGPoint(x: 210, y: 10), uptime: 10.01), [other])
        XCTAssertEqual(reads, 1, "one list serves inputs close together")
        screen = [other]
        XCTAssertEqual(log.windows(at: CGPoint(x: 10, y: 10), uptime: 10 + UserInputLog.windowListReuseSeconds + 0.01), [])
        XCTAssertEqual(reads, 2)
    }

    func testAScrollAtOnePlaceKeepsTheLatestWindows() {
        let first = UserActivity.ScreenWindow(pid: 100, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let second = UserActivity.ScreenWindow(pid: 200, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let log = UserInputLog(readWindows: { [] })
        log.recordPointer(at: CGPoint(x: 5, y: 5), uptime: 10, windows: [first])
        log.recordPointer(at: CGPoint(x: 5, y: 5), uptime: 11, windows: [second])
        XCTAssertEqual(log.snapshot().pointerInputs.map(\.windows), [[second]])
    }

    func testCoverageFollowsTheTap() {
        let log = UserInputLog()
        XCTAssertNil(log.snapshot().pointerLogSince)
        log.pointerTapEnabled(at: 5)
        XCTAssertEqual(log.snapshot().pointerLogSince, 5)
        log.pointerTapDisabled()
        XCTAssertNil(log.snapshot().pointerLogSince)
        log.pointerTapEnabled(at: 9)
        XCTAssertEqual(log.snapshot().pointerLogSince, 9)
    }

    func testFrontmostAtAnEarlierTime() {
        let log = UserInputLog()
        log.recordActivation(pid: 1, uptime: 10)
        log.recordActivation(pid: 2, uptime: 20)
        let frontmostAt = log.snapshot().frontmostAt
        XCTAssertNil(frontmostAt(9))
        XCTAssertEqual(frontmostAt(10), 1)
        XCTAssertEqual(frontmostAt(19.9), 1)
        XCTAssertEqual(frontmostAt(25), 2)
    }

    func testOldActivationsArePrunedButTheOneInFrontAtTheWindowStartStays() {
        let log = UserInputLog()
        log.recordActivation(pid: 1, uptime: 0)
        log.recordActivation(pid: 2, uptime: 1)
        log.recordActivation(pid: 3, uptime: 100)
        let frontmostAt = log.snapshot().frontmostAt
        XCTAssertNil(frontmostAt(0.5))
        XCTAssertEqual(frontmostAt(99), 2)
        XCTAssertEqual(frontmostAt(100), 3)
    }

    @MainActor
    func testStopDropsEveryRecordAndTheCoverage() {
        let log = UserInputLog(readWindows: { [] })
        log.pointerTapEnabled(at: 5)
        log.recordPointer(at: CGPoint(x: 1, y: 1), uptime: 10)
        log.recordActivation(pid: 1, uptime: 10)
        log.stop()
        let snapshot = log.snapshot()
        XCTAssertEqual(snapshot.pointerInputs, [])
        XCTAssertNil(snapshot.pointerLogSince)
        XCTAssertNil(snapshot.frontmostAt(10))
    }

    func testALiveRecordIsDroppedWhileTheLogIsStopped() {
        // No tap runs, as after a stop: a tap callback that was already
        // running when the log stopped adds nothing.
        let log = UserInputLog(readWindows: { [] })
        log.recordLivePointer(at: CGPoint(x: 1, y: 1), uptime: 10, windows: [])
        XCTAssertEqual(log.snapshot().pointerInputs, [])
    }

    func testOnlyHardwareMouseDownsAndScrollsAreKept() {
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            XCTAssertTrue(UserInputLog.shouldRecord(type: type, sourcePid: 0, userData: 0), "\(type.rawValue)")
        }
        for type in [CGEventType.keyDown, .keyUp, .mouseMoved, .leftMouseDragged, .leftMouseUp, .flagsChanged] {
            XCTAssertFalse(UserInputLog.shouldRecord(type: type, sourcePid: 0, userData: 0), "\(type.rawValue)")
        }
        XCTAssertFalse(UserInputLog.shouldRecord(type: .leftMouseDown, sourcePid: 0, userData: kPaseoSyntheticEventUserData))
        XCTAssertFalse(UserInputLog.shouldRecord(type: .leftMouseDown, sourcePid: 77, userData: 0))
    }
}
