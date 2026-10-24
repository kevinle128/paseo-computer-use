import CoreGraphics
import XCTest
@testable import PaseoComputerUseCore

final class MotionPhysicsTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let dt = 1.0 / 120.0

    private func run(
        from start: CGPoint,
        to end: CGPoint,
        limit: Double = 3.0
    ) -> (samples: [CursorMotionSample], settledAt: Double?) {
        var stepper = CursorMotionStepper(start: start, end: end, screenBounds: bounds)
        var samples: [CursorMotionSample] = []
        var time = 0.0
        while time < limit {
            let sample = stepper.step(dt: dt)
            time += dt
            samples.append(sample)
            if sample.settled { return (samples, time) }
        }
        return (samples, nil)
    }

    func testReachesEndPointAndSettlesInBoundedTime() {
        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 100, y: 100), CGPoint(x: 1300, y: 800)),
            (CGPoint(x: 700, y: 400), CGPoint(x: 720, y: 410)),
            (CGPoint(x: 1300, y: 80), CGPoint(x: 90, y: 820)),
        ]
        let config = MotionConfiguration.live
        for (start, end) in cases {
            let result = run(from: start, to: end)
            XCTAssertNotNil(result.settledAt, "never settled from \(start) to \(end)")
            // A glide that only ends at the hard time limit (twice the travel
            // time) is not settled; convergence must come before it.
            let travel = min(config.maxDuration, max(config.minDuration, config.minDuration + hypot(Double(end.x - start.x), Double(end.y - start.y)) * config.secondsPerPoint))
            XCTAssertLessThan(result.settledAt ?? .infinity, travel * 1.7, "settled only at the time limit")
            let last = result.samples.last
            XCTAssertEqual(Double(last?.position.x ?? -1), Double(end.x), accuracy: 1.0)
            XCTAssertEqual(Double(last?.position.y ?? -1), Double(end.y), accuracy: 1.0)
        }
    }

    func testZeroDistanceSettlesImmediately() {
        let point = CGPoint(x: 300, y: 300)
        var stepper = CursorMotionStepper(start: point, end: point, screenBounds: bounds)
        var sample = stepper.step(dt: dt)
        for _ in 0..<300 where !sample.settled { sample = stepper.step(dt: dt) }
        XCTAssertTrue(sample.settled)
        XCTAssertEqual(sample.position, point)
    }

    func testOvershootAlongTheChordIsSmall() {
        let start = CGPoint(x: 100, y: 450)
        let end = CGPoint(x: 1300, y: 450)
        let result = run(from: start, to: end)
        let furthest = result.samples.map { Double($0.position.x) }.max() ?? 0
        let distance = Double(end.x - start.x)
        XCTAssertLessThan(furthest - Double(end.x), distance * 0.03)
    }

    func testPathStaysInsideScreenBounds() {
        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 2, y: 2), CGPoint(x: 1438, y: 2)),
            (CGPoint(x: 1438, y: 898), CGPoint(x: 2, y: 898)),
            (CGPoint(x: 5, y: 450), CGPoint(x: 5, y: 880)),
        ]
        for (start, end) in cases {
            for sample in run(from: start, to: end).samples {
                XCTAssertTrue(bounds.contains(sample.position), "\(sample.position) left the screen")
            }
        }
    }

    func testPathBendsSidewaysButLandsOnTheEndPoint() {
        let start = CGPoint(x: 200, y: 450)
        let end = CGPoint(x: 1200, y: 450)
        let result = run(from: start, to: end)
        let widest = result.samples.map { abs(Double($0.position.y) - 450) }.max() ?? 0
        XCTAssertGreaterThan(widest, 5)
        XCTAssertEqual(Double(result.samples.last?.position.y ?? 0), 450, accuracy: 0.5)
    }

    func testRestartingMidMoveIsContinuous() {
        var first = CursorMotionStepper(
            start: CGPoint(x: 100, y: 100),
            end: CGPoint(x: 1300, y: 800),
            screenBounds: bounds
        )
        var midway = first.step(dt: dt)
        for _ in 0..<20 { midway = first.step(dt: dt) }
        XCTAssertFalse(midway.settled)

        var second = CursorMotionStepper(
            start: midway.position,
            end: CGPoint(x: 200, y: 700),
            screenBounds: bounds
        )
        let next = second.step(dt: dt)
        let jump = hypot(
            Double(next.position.x - midway.position.x),
            Double(next.position.y - midway.position.y)
        )
        // One frame from rest moves the pointer a few points at most; a
        // restart that jumped would show as tens of points.
        XCTAssertLessThan(jump, 8.0)
    }

    func testTiltAndStretchAreBoundedAndReturnToRest() {
        let config = MotionConfiguration.live
        let result = run(from: CGPoint(x: 100, y: 450), to: CGPoint(x: 1300, y: 450))
        for sample in result.samples {
            XCTAssertLessThanOrEqual(abs(sample.rotationDegrees - config.clickAngle), config.maxTiltDegrees + 1e-9)
            XCTAssertGreaterThanOrEqual(sample.scaleX, 1.0)
            XCTAssertLessThanOrEqual(sample.scaleX, 1.0 + config.maxStretch + 1e-9)
            XCTAssertLessThanOrEqual(sample.scaleY, 1.0)
            XCTAssertGreaterThanOrEqual(sample.scaleY, 1.0 - config.maxSquash - 1e-9)
        }
        let last = result.samples.last
        XCTAssertEqual(last?.rotationDegrees, config.clickAngle)
        XCTAssertEqual(last?.scaleX, 1.0)
        XCTAssertEqual(last?.scaleY, 1.0)
    }

    func testLongStepMatchesManyShortSteps() {
        var coarse = CursorMotionStepper(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 900, y: 600), screenBounds: bounds)
        var fine = coarse
        let a = coarse.step(dt: 0.1)
        var b = fine.step(dt: 0.0)
        for _ in 0..<12 { b = fine.step(dt: 0.1 / 12) }
        XCTAssertEqual(Double(a.position.x), Double(b.position.x), accuracy: 3.0)
        XCTAssertEqual(Double(a.position.y), Double(b.position.y), accuracy: 3.0)
    }
}
