import Foundation

/// Holds the window server's screen updates for a very short time, so a
/// correction of the frontmost app shows as one change and not as a flash of
/// the app that took focus.
///
/// A hold that is never released freezes the screen, so every hold has two
/// ways to end: the body ends (normally or with an error), or a watchdog ends
/// it `cap` seconds after it began. Whichever comes first releases; the other
/// does nothing, because the window server counts holds and one extra release
/// would undo a hold that is not ours. When the hold primitives are missing
/// there is no gate at all (`live()` returns nil) and the caller runs its
/// steps without one.
///
/// The live watchdog fires on its own queue, so the cap holds while the main
/// thread, which runs the correction, is stalled. Its release waits for no
/// thread: the hold and the release go through `WindowServerCalls`, like
/// every other private window server call of the helper, so the release
/// waits at most for one such call that is in flight and never runs at the
/// same time as one.
///
/// The gate has no clock, timer, or window server call of its own, so tests
/// drive it with fakes.
public final class ScreenUpdateGate: @unchecked Sendable {
    /// The longest a hold may last.
    public static let capSeconds: Double = 0.25

    public struct Primitives {
        /// Stops screen updates. False when the window server refused, and
        /// then nothing is held and nothing is released.
        public let hold: () -> Bool
        /// Lets screen updates go on again.
        public let release: () -> Void

        public init(hold: @escaping () -> Bool, release: @escaping () -> Void) {
            self.hold = hold
            self.release = release
        }
    }

    public enum ReleasedBy: String, Equatable, Sendable {
        /// The body ended, normally or with an error.
        case body
        /// The watchdog ended a body that ran for longer than the cap.
        case watchdog
    }

    /// What one hold did, for the audit log.
    public struct Report: Equatable, Sendable {
        /// From the hold to the end of its release, as measured. It is more
        /// than the cap when the watchdog came late, its release waited for a
        /// window server call in flight, or the body ended past the cap first.
        public let heldMs: Int
        public let releasedBy: ReleasedBy
        /// The hold lasted longer than the cap.
        public let overCap: Bool

        public init(heldMs: Int, releasedBy: ReleasedBy, overCap: Bool = false) {
            self.heldMs = heldMs
            self.releasedBy = releasedBy
            self.overCap = overCap
        }
    }

    /// Runs `fire` once, `delay` seconds from now, on a thread other than the
    /// one that runs the body, so it fires while that body stalls.
    public typealias Watchdog = (_ delay: Double, _ fire: @escaping () -> Void) -> Void

    private let primitives: Primitives
    private let cap: Double
    private let now: () -> Double
    private let watchdog: Watchdog

    public init(
        primitives: Primitives,
        cap: Double = ScreenUpdateGate.capSeconds,
        now: @escaping () -> Double,
        watchdog: @escaping Watchdog
    ) {
        self.primitives = primitives
        self.cap = cap
        self.now = now
        self.watchdog = watchdog
    }

    /// One hold: released exactly once, by the first of the body and the
    /// watchdog.
    private final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var report: Report?
        let start: Double

        init(start: Double) {
            self.start = start
        }

        /// Returns true for the first caller only; that caller releases and
        /// then calls `released(at:cap:)`.
        func end(at time: Double, by: ReleasedBy, cap: Double) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard report == nil else { return false }
            report = Self.report(start: start, end: time, by: by, cap: cap)
            return true
        }

        /// The release returned at `time`. The release can wait for a window
        /// server call in flight, so the hold is measured to here.
        func released(at time: Double, cap: Double) {
            lock.lock()
            defer { lock.unlock() }
            guard let by = report?.releasedBy else { return }
            report = Self.report(start: start, end: time, by: by, cap: cap)
        }

        private static func report(start: Double, end: Double, by: ReleasedBy, cap: Double) -> Report {
            let held = max(0, end - start)
            return Report(heldMs: Int((held * 1000).rounded()), releasedBy: by, overCap: held > cap)
        }

        var result: Report? {
            lock.lock()
            defer { lock.unlock() }
            return report
        }
    }

    /// Runs `body` with screen updates held. The report is nil when the
    /// window server refused the hold, so the body ran without one.
    public func run<T>(_ body: () throws -> T) rethrows -> (value: T, report: Report?) {
        guard primitives.hold() else {
            return (try body(), nil)
        }
        let hold = Hold(start: now())
        let cap = self.cap
        let release = primitives.release
        let now = self.now
        let end = { (by: ReleasedBy) in
            guard hold.end(at: now(), by: by, cap: cap) else { return }
            release()
            hold.released(at: now(), cap: cap)
        }
        watchdog(cap) { end(.watchdog) }
        defer { end(.body) }
        let value = try body()
        // The defer above has not run yet, so end the hold here to report it.
        end(.body)
        return (value, hold.result)
    }

    /// The queue the live watchdog fires on. It is not the main thread, which
    /// runs the correction, so a stalled main thread cannot keep the screen
    /// held.
    static let watchdogQueue = DispatchQueue(label: "paseo.computer-use.screen-update-watchdog", qos: .userInteractive)

    /// The live watchdog: `fire` runs on `watchdogQueue` `delay` seconds from
    /// now.
    static func queueWatchdog(delay: Double, fire: @escaping () -> Void) {
        watchdogQueue.asyncAfter(deadline: .now() + delay, execute: fire)
    }

    /// A gate over the window server's update hold, or nil when the helper
    /// cannot find the calls.
    public static func live() -> ScreenUpdateGate? {
        guard let primitives = WindowServer.shared.screenUpdatePrimitives() else { return nil }
        return ScreenUpdateGate(
            primitives: primitives,
            now: { ProcessInfo.processInfo.systemUptime },
            watchdog: queueWatchdog
        )
    }
}
