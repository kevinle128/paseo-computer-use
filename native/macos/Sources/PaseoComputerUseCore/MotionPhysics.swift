import CoreGraphics
import Foundation

// Pointer motion model.
//
// The pointer travels along the straight line from `start` to `end`. A single
// scalar `progress` (0 at the start, 1 at the end) follows a damped spring:
//
//     progress'' = w^2 * (1 - progress) - 2 * zeta * w * progress'
//
// With zeta just under 1 the spring is almost critically damped. The pointer
// accelerates smoothly, slows down without a visible bounce, and may pass the
// end by a fraction of a point before it comes back. The natural frequency
// `w` follows from a travel time that grows with distance and is capped, so a
// short hop is quick and a cross-screen glide still ends soon after the agent
// acts.
//
// A mild arc is a perpendicular offset of the straight line:
// `bowFraction * distance * 4 * p * (1 - p)` with p clamped to 0...1. It is
// zero at both ends, so the pointer lands exactly on the end point, and it
// peaks mid-flight. Every position is clamped to the bounds, so a bow near an
// edge is flattened instead of leaving the area.
//
// The arrow leans into horizontal movement and stretches a little while it is
// fast. Both effects come from the measured pointer velocity and fade back to
// the resting angle and unit scale as the pointer slows down.
//
// The only state is the spring, so a new glide that starts from the current
// pointer position continues without a jump in position. It starts at rest,
// so tilt and stretch return to their resting values at a redirect instead of
// carrying over.

public struct MotionConfiguration: Sendable, Equatable {
    /// Resting rotation of the arrow in degrees.
    public var clickAngle: Double
    /// Shortest and longest travel time in seconds.
    public var minDuration: Double
    public var maxDuration: Double
    /// Extra travel time per point of distance, in seconds.
    public var secondsPerPoint: Double
    /// Damping ratio of the progress spring. Below 1 allows a tiny overshoot.
    public var dampingRatio: Double
    /// Peak sideways offset of the arc as a fraction of the distance.
    public var bowFraction: Double
    /// Largest sideways offset in points.
    public var maxBow: Double
    /// Moves not longer than this many points stay straight.
    public var straightDistance: Double
    /// Speed in points per second at which tilt and stretch reach their limit.
    public var referenceSpeed: Double
    /// Largest lean in degrees away from the resting angle.
    public var maxTiltDegrees: Double
    /// Largest stretch and squash added to the unit scale.
    public var maxStretch: Double
    public var maxSquash: Double

    public init(
        clickAngle: Double = -44.0,
        minDuration: Double = 0.22,
        maxDuration: Double = 0.7,
        secondsPerPoint: Double = 1.0 / 2400.0,
        dampingRatio: Double = 0.95,
        bowFraction: Double = 0.1,
        maxBow: Double = 60.0,
        straightDistance: Double = 10.0,
        referenceSpeed: Double = 1800.0,
        maxTiltDegrees: Double = 14.0,
        maxStretch: Double = 0.1,
        maxSquash: Double = 0.05
    ) {
        self.clickAngle = clickAngle
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.secondsPerPoint = secondsPerPoint
        self.dampingRatio = dampingRatio
        self.bowFraction = bowFraction
        self.maxBow = maxBow
        self.straightDistance = straightDistance
        self.referenceSpeed = referenceSpeed
        self.maxTiltDegrees = maxTiltDegrees
        self.maxStretch = maxStretch
        self.maxSquash = maxSquash
    }

    public static let live = MotionConfiguration()
}

public struct CursorMotionSample: Sendable, Equatable {
    public let position: CGPoint
    public let rotationDegrees: Double
    public let scaleX: Double
    public let scaleY: Double
    public let settled: Bool

    public init(
        position: CGPoint,
        rotationDegrees: Double,
        scaleX: Double,
        scaleY: Double,
        settled: Bool
    ) {
        self.position = position
        self.rotationDegrees = rotationDegrees
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.settled = settled
    }
}

public struct CursorMotionStepper: Sendable {
    /// Largest integration step. A longer `dt` is split so the spring stays
    /// stable at any frame rate.
    private static let maxSubstep = 1.0 / 240.0
    /// Remaining distance in points under which the pointer counts as arrived.
    private static let arrivalDistance = 0.5
    /// Pointer speed in points per second under which it counts as at rest.
    private static let restSpeed = 20.0

    public let start: CGPoint
    public let end: CGPoint
    public let distance: Double
    public let configuration: MotionConfiguration

    private let screenBounds: CGRect
    private let naturalFrequency: Double
    private let timeLimit: Double
    private let bowNormal: CGVector
    private let bowAmplitude: Double

    private var progress = 0.0
    private var progressVelocity = 0.0
    private var elapsed = 0.0
    private var current: CGPoint
    private var velocity = CGVector.zero
    private var finished = false

    public init(
        start: CGPoint,
        end: CGPoint,
        screenBounds: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
        configuration: MotionConfiguration = .live
    ) {
        self.start = start
        self.end = end
        self.configuration = configuration
        self.screenBounds = screenBounds
        self.current = start

        let dx = Double(end.x - start.x)
        let dy = Double(end.y - start.y)
        let dist = hypot(dx, dy)
        self.distance = dist

        let duration = min(
            configuration.maxDuration,
            max(configuration.minDuration, configuration.minDuration + dist * configuration.secondsPerPoint)
        )
        // Six over the travel time leaves about one percent of the distance
        // when the travel time has passed; the tail ends within the time limit.
        self.naturalFrequency = 6.0 / duration
        self.timeLimit = duration * 2.0

        if dist > configuration.straightDistance {
            let amplitude = min(configuration.maxBow, dist * configuration.bowFraction)
            let unit = CGVector(dx: -dy / dist, dy: dx / dist)
            // The bow leans upward on screen.
            let sign: Double = unit.dy <= 0 ? 1 : -1
            self.bowNormal = CGVector(dx: sign * unit.dx, dy: sign * unit.dy)
            self.bowAmplitude = amplitude
        } else {
            self.bowNormal = .zero
            self.bowAmplitude = 0
        }
    }

    public mutating func step(dt: Double) -> CursorMotionSample {
        var remaining = max(0.0, dt)
        while remaining > 0, !finished {
            let h = min(remaining, Self.maxSubstep)
            remaining -= h
            advance(by: h)
        }
        if finished {
            return CursorMotionSample(
                position: end,
                rotationDegrees: configuration.clickAngle,
                scaleX: 1.0,
                scaleY: 1.0,
                settled: true
            )
        }
        let speed = hypot(velocity.dx, velocity.dy)
        let fast = min(1.0, speed / configuration.referenceSpeed)
        let lean = tanh(velocity.dx / configuration.referenceSpeed)
        return CursorMotionSample(
            position: current,
            rotationDegrees: configuration.clickAngle + configuration.maxTiltDegrees * lean,
            scaleX: 1.0 + configuration.maxStretch * fast,
            scaleY: 1.0 - configuration.maxSquash * fast,
            settled: false
        )
    }

    private mutating func advance(by h: Double) {
        let w = naturalFrequency
        let acceleration = w * w * (1.0 - progress) - 2.0 * configuration.dampingRatio * w * progressVelocity
        progressVelocity += acceleration * h
        progress += progressVelocity * h
        elapsed += h

        let next = point(atProgress: progress)
        velocity = CGVector(dx: Double(next.x - current.x) / h, dy: Double(next.y - current.y) / h)
        current = next

        let remainingDistance = hypot(Double(end.x - next.x), Double(end.y - next.y))
        let atRest = hypot(velocity.dx, velocity.dy) < Self.restSpeed
        if (remainingDistance < Self.arrivalDistance && atRest) || elapsed >= timeLimit {
            finished = true
        }
    }

    private func point(atProgress p: Double) -> CGPoint {
        let clamped = min(1.0, max(0.0, p))
        let bow = bowAmplitude * 4.0 * clamped * (1.0 - clamped)
        let x = Double(start.x) + p * Double(end.x - start.x) + bow * Double(bowNormal.dx)
        let y = Double(start.y) + p * Double(end.y - start.y) + bow * Double(bowNormal.dy)
        return CGPoint(
            x: min(Double(screenBounds.maxX), max(Double(screenBounds.minX), x)),
            y: min(Double(screenBounds.maxY), max(Double(screenBounds.minY), y))
        )
    }
}
