import CoreGraphics
import Foundation

/// One glide of the virtual pointer from one point to another. The owner
/// advances it once per display frame; it runs the shared cursor physics in
/// fixed small steps, so the motion is the same at any frame rate.
public struct PointerAnimator: Sendable {
    public static let physicsStep = 1.0 / 120.0

    public let destination: CGPoint
    public private(set) var sample: CursorMotionSample
    private var stepper: CursorMotionStepper
    private var pendingTime = 0.0
    private var elapsed = 0.0
    private let maxDuration: Double
    private let clickAngle: Double

    public var isFinished: Bool { sample.settled }

    /// `bounds` keeps the curved path near the area the pointer moves in.
    /// `maxDuration` is a safety net above the longest settle time of the
    /// motion model (a 0.7 s travel time plus its tail), so a glide of any
    /// length settles on its own and the pointer reaches the click point soon
    /// after the click.
    public init(
        from start: CGPoint,
        to end: CGPoint,
        bounds: CGRect,
        maxDuration: Double = 1.2,
        configuration: MotionConfiguration = .live
    ) {
        destination = end
        self.maxDuration = maxDuration
        clickAngle = configuration.clickAngle
        stepper = CursorMotionStepper(start: start, end: end, screenBounds: bounds, configuration: configuration)
        let alreadyThere = hypot(Double(end.x - start.x), Double(end.y - start.y)) < 1.0
        sample = CursorMotionSample(
            position: alreadyThere ? end : start,
            rotationDegrees: configuration.clickAngle,
            scaleX: 1.0,
            scaleY: 1.0,
            settled: alreadyThere
        )
    }

    @discardableResult
    public mutating func advance(by seconds: Double) -> CursorMotionSample {
        guard !isFinished else { return sample }
        pendingTime += max(0.0, seconds)
        while pendingTime >= Self.physicsStep, !sample.settled {
            pendingTime -= Self.physicsStep
            elapsed += Self.physicsStep
            sample = stepper.step(dt: Self.physicsStep)
            if elapsed >= maxDuration, !sample.settled {
                sample = CursorMotionSample(
                    position: destination,
                    rotationDegrees: clickAngle,
                    scaleX: 1.0,
                    scaleY: 1.0,
                    settled: true
                )
            }
        }
        return sample
    }
}
