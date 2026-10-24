import CoreGraphics
import Foundation

/// Timings of the overlay, in seconds.
public struct OverlayTiming: Sendable, Equatable {
    /// The pointer stays at the point it acted on this long, then fades.
    public var pointerHold: Double = 1.5
    public var pointerFade: Double = 0.3
    /// The fade of the whole overlay after `hide()` or the watchdog.
    public var overlayFade: Double = 0.25
    /// With no activity for this long the overlay hides itself, so a lost
    /// hide message can never leave it on the screen.
    public var watchdog: Double = 5.0
    public var pulseDuration: Double = 0.18
    public var pulseScale: Double = 0.86

    public init() {}

    public static let live = OverlayTiming()
}

/// What the overlay shows in one frame. Frames are global display
/// coordinates (top-left origin); the surface converts them.
public struct OverlayPointerFrame: Equatable, Sendable {
    public var position: CGPoint
    public var rotationDegrees: Double
    public var scaleX: Double
    public var scaleY: Double
    public var pulseScale: Double
    public var alpha: Double
    /// The name of the agent that controls the pointer, shown next to it.
    public var label: String
}

public struct OverlayFrame: Equatable, Sendable {
    /// The bounds of the window the agent acts on, or nil to show no halo.
    public var haloFrame: CGRect?
    public var pointer: OverlayPointerFrame?
    /// The alpha of the whole overlay; below 1 while it fades out.
    public var alpha: Double
}

/// Draws overlay frames. The AppKit implementation owns the panels; tests
/// record the frames instead.
@MainActor
public protocol OverlaySurface: AnyObject {
    func render(_ frame: OverlayFrame)
    func hide()
}

/// Calls the presenter once per display frame while it runs.
@MainActor
public protocol OverlayFrameScheduler: AnyObject {
    var isRunning: Bool { get }
    func start(_ onFrame: @escaping @MainActor () -> Void)
    func stop()
}

/// A main run loop timer at 120 Hz. It runs only while the overlay is on
/// screen, so a hidden overlay costs nothing.
@MainActor
public final class RunLoopFrameScheduler: OverlayFrameScheduler {
    private var timer: Timer?

    public init() {}

    public var isRunning: Bool { timer != nil }

    public func start(_ onFrame: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
            MainActor.assumeIsolated { onFrame() }
        }
        // Common modes keep the animation going while a menu tracks events.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// The one owner of the virtual pointer and the window halo.
///
/// States: `hidden` -> `active` (a target window, an optional glide) ->
/// `fading` -> `hidden`. Input actions call `pointerMove` and `pulse` and do
/// not wait for the animation; the frame scheduler advances it. The plugin
/// calls `hide()` (through `end_turn`) whenever the agent gives the computer
/// back, and the watchdog hides the overlay when no activity comes.
@MainActor
public final class OverlayPresenter {
    public enum State: Equatable, Sendable {
        case hidden
        case active
        case fading
    }

    public static let shared = OverlayPresenter(
        surface: PanelOverlaySurface(),
        scheduler: RunLoopFrameScheduler(),
        clock: { ProcessInfo.processInfo.systemUptime }
    )

    public private(set) var state: State = .hidden

    /// The label the pointer shows when no command has named the agent.
    public static let defaultLabel = "Agent"

    /// The name of the agent that moved the pointer last. A hide keeps it,
    /// so a command that sends no label still shows the last known agent.
    public private(set) var label: String = OverlayPresenter.defaultLabel

    private let surface: OverlaySurface
    private let scheduler: OverlayFrameScheduler
    private let clock: () -> TimeInterval
    private let timing: OverlayTiming

    private var targetWindow: CGRect?
    private var animator: PointerAnimator?
    private var pointerSample: CursorMotionSample?
    private var pointerDestination: CGPoint?
    private var pulseQueued = false
    private var pulseStart: TimeInterval?
    private var lastActivity: TimeInterval = 0
    private var lastPointerActivity: TimeInterval = 0
    private var fadeStart: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    // Kept after a hide so the next glide starts where the pointer was last
    // seen, not from a fixed corner.
    private var lastShownPosition: CGPoint?
    // The last frame sent to the surface. The frame timer ticks at 120 Hz
    // also while nothing moves, and an equal frame needs no redraw.
    private var lastRendered: OverlayFrame?

    public init(
        surface: OverlaySurface,
        scheduler: OverlayFrameScheduler,
        clock: @escaping () -> TimeInterval,
        timing: OverlayTiming = .live
    ) {
        self.surface = surface
        self.scheduler = scheduler
        self.clock = clock
        self.timing = timing
    }

    /// The point the pointer acted on, while the pointer is on screen. Nil
    /// when it is hidden or has faded, so a screenshot never marks a stale
    /// pointer.
    public var currentPosition: CGPoint? {
        guard state != .hidden, pointerSample != nil else { return nil }
        return pointerAlpha(at: clock()) > 0 ? pointerDestination : nil
    }

    /// Glides the pointer to `point` and outlines `window`. Both are global
    /// display coordinates. A move during a glide replaces it and starts
    /// from where the pointer is now. A nil or empty `label` keeps the last
    /// one, so an older plugin that sends no label still works.
    public func pointerMove(to point: CGPoint, window: CGRect?, label: String? = nil) {
        let now = clock()
        if let label {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.label = trimmed
            }
        }
        let start = pointerSample?.position ?? lastShownPosition ?? window.map { CGPoint(x: $0.midX, y: $0.midY) } ?? point
        var bounds = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        if let window {
            bounds = bounds.union(window)
        }
        let glide = PointerAnimator(from: start, to: point, bounds: bounds.insetBy(dx: -100, dy: -100))
        animator = glide.isFinished ? nil : glide
        pointerSample = glide.sample
        pointerDestination = point
        targetWindow = window
        pulseQueued = false
        pulseStart = nil
        lastActivity = now
        lastPointerActivity = now
        if state == .hidden {
            lastFrameTime = now
        }
        state = .active
        startFrames()
        render(at: now)
    }

    /// A click press. It plays when the pointer reaches the click point, so
    /// it never shows before the pointer arrives.
    public func pulse() {
        guard state == .active, pointerSample != nil else { return }
        let now = clock()
        lastActivity = now
        lastPointerActivity = now
        if animator != nil {
            pulseQueued = true
        } else {
            pulseStart = now
        }
    }

    /// Marks a keyboard or value action on the target window, so the
    /// watchdog does not fade the halo while the agent still types. It only
    /// extends an overlay that is on screen: a keyboard-only action never
    /// shows it, and it never brings back an overlay that fades or is
    /// hidden. The pointer still fades after its hold, because it marks a
    /// click point and not the typing.
    public func keepAlive() {
        guard state == .active else { return }
        lastActivity = clock()
    }

    /// Fades the overlay out. The plugin calls it when the agent no longer
    /// owns the computer.
    public func hide() {
        guard state == .active else { return }
        state = .fading
        fadeStart = clock()
        startFrames()
    }

    /// Advances one display frame. The scheduler calls it; tests call it
    /// directly.
    public func tick() {
        let now = clock()
        let dt = min(0.05, max(0.0, now - lastFrameTime))
        lastFrameTime = now

        switch state {
        case .hidden:
            scheduler.stop()
            return
        case .active:
            if var glide = animator {
                pointerSample = glide.advance(by: dt)
                if glide.isFinished {
                    animator = nil
                    lastActivity = now
                    lastPointerActivity = now
                    if pulseQueued {
                        pulseQueued = false
                        pulseStart = now
                    }
                } else {
                    animator = glide
                }
            }
            if now - lastActivity >= timing.watchdog {
                state = .fading
                fadeStart = now
            }
        case .fading:
            if now - fadeStart >= timing.overlayFade {
                finishHide()
                return
            }
        }
        render(at: now)
    }

    private func startFrames() {
        if !scheduler.isRunning {
            scheduler.start { [weak self] in self?.tick() }
        }
    }

    private func finishHide() {
        state = .hidden
        lastShownPosition = pointerSample?.position ?? lastShownPosition
        targetWindow = nil
        animator = nil
        pointerSample = nil
        pointerDestination = nil
        pulseQueued = false
        pulseStart = nil
        lastRendered = nil
        surface.hide()
        scheduler.stop()
    }

    private func pointerAlpha(at now: TimeInterval) -> Double {
        if animator != nil || pulseQueued {
            return 1.0
        }
        let idle = now - lastPointerActivity - timing.pointerHold
        if idle <= 0 {
            return 1.0
        }
        return max(0.0, 1.0 - idle / timing.pointerFade)
    }

    private func pulseScale(at now: TimeInterval) -> Double {
        guard let start = pulseStart else { return 1.0 }
        let progress = (now - start) / timing.pulseDuration
        if progress >= 1.0 {
            pulseStart = nil
            return 1.0
        }
        return 1.0 - (1.0 - timing.pulseScale) * sin(Double.pi * max(0.0, progress))
    }

    private func render(at now: TimeInterval) {
        let overlayAlpha = state == .fading
            ? max(0.0, 1.0 - (now - fadeStart) / timing.overlayFade)
            : 1.0
        var pointer: OverlayPointerFrame?
        if let sample = pointerSample {
            let alpha = pointerAlpha(at: now)
            if alpha > 0 {
                pointer = OverlayPointerFrame(
                    position: sample.position,
                    rotationDegrees: sample.rotationDegrees,
                    scaleX: sample.scaleX,
                    scaleY: sample.scaleY,
                    pulseScale: pulseScale(at: now),
                    alpha: alpha,
                    label: label
                )
            }
        }
        let frame = OverlayFrame(haloFrame: targetWindow, pointer: pointer, alpha: overlayAlpha)
        guard frame != lastRendered else { return }
        lastRendered = frame
        surface.render(frame)
    }
}
