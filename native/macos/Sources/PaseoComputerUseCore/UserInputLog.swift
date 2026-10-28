import AppKit
import CoreGraphics
import Foundation

/// Remembers, for a few seconds, where the user pressed a mouse button or
/// scrolled and which app was frontmost when. `UserActivity` reads it to tell
/// input to the action's target from input to another app.
///
/// Pointer input comes from a listen-only event tap for mouse downs and
/// scrolls. It never sees key events, so it needs no Input Monitoring
/// permission, and it cannot delay or change an event. It runs on its own
/// thread, so the time it takes for an event does not wait for a busy main
/// thread. It keeps only the time, the location, and the frames and owner
/// pids of the on-screen windows at that location when the input came, in
/// memory, and drops them after `retentionSeconds`. The window list is read at
/// most once every `windowListReuseSeconds` (a scroll sends many events).
///
/// The frontmost app at an earlier moment comes from the workspace activation
/// notices, kept with the time they arrived.
///
/// The log runs only while an agent controls the computer: `ControlInputWatch`
/// starts it when the plugin arms the Escape stop key and stops it when the
/// plugin disarms it or the user stops the agent. A stop drops every record.
public final class UserInputLog: @unchecked Sendable, PointerInputWatch {
    public static let shared = UserInputLog()

    /// How long a record is kept: the pause window and a margin.
    static let retentionSeconds = UserActivity.pauseSeconds + 1
    /// A bound on the pointer records. A scroll at one place is folded into
    /// one record, so this is reached only by scrolling while moving.
    static let maxPointerInputs = 512
    static let maxActivations = 64
    /// How long one read of the window list serves the pointer inputs that
    /// follow it.
    static let windowListReuseSeconds = 0.05

    public struct Snapshot {
        public let pointerInputs: [UserActivity.PointerInput]
        public let pointerLogSince: Double?
        public let frontmostAt: (Double) -> pid_t?
    }

    private struct Activation {
        let uptime: Double
        let pid: pid_t
    }

    private let lock = NSLock()
    private var pointerInputs: [UserActivity.PointerInput] = []
    private var pointerLogSince: Double?
    private var activations: [Activation] = []
    /// The live tap and the run loop of its thread. Nil while the log is
    /// stopped, so a tap callback that is already running when the log
    /// stops adds nothing. Guarded by `lock`.
    private var eventTap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    /// The start that the tap thread belongs to. A stop clears it, so a tap
    /// thread that starts late finds it changed and ends. Guarded by `lock`.
    private var tapGeneration = 0
    private var activeTapGeneration: Int?
    /// Main thread only.
    private var started = false
    private var activationObserver: NSObjectProtocol?
    /// Reads the on-screen windows, frontmost first.
    private let readWindows: () -> [UserActivity.ScreenWindow]
    /// The last window list read and when. Used on the tap thread only.
    private var windowList: (uptime: Double, windows: [UserActivity.ScreenWindow])?

    init(readWindows: @escaping () -> [UserActivity.ScreenWindow] = UserActivity.liveScreenWindows) {
        self.readWindows = readWindows
    }

    // MARK: Records

    /// Adds one hardware mouse down or scroll, with the windows at its
    /// location when it came. A record at the same place as the previous one
    /// only moves that record's time and windows: a scroll sends many events
    /// while the pointer stays put.
    func recordPointer(at location: CGPoint, uptime: Double, windows: [UserActivity.ScreenWindow]? = nil) {
        lock.lock()
        defer { lock.unlock() }
        recordPointerLocked(at: location, uptime: uptime, windows: windows)
    }

    /// Adds a record from the live tap, only while the log runs.
    func recordLivePointer(at location: CGPoint, uptime: Double, windows: [UserActivity.ScreenWindow]) {
        lock.lock()
        defer { lock.unlock() }
        guard eventTap != nil else { return }
        recordPointerLocked(at: location, uptime: uptime, windows: windows)
    }

    private func recordPointerLocked(at location: CGPoint, uptime: Double, windows: [UserActivity.ScreenWindow]?) {
        pruneLocked(now: uptime)
        if let last = pointerInputs.last, last.location == location {
            pointerInputs[pointerInputs.count - 1] = UserActivity.PointerInput(
                uptime: uptime,
                location: location,
                windows: windows ?? last.windows
            )
            return
        }
        pointerInputs.append(UserActivity.PointerInput(uptime: uptime, location: location, windows: windows))
        if pointerInputs.count > Self.maxPointerInputs {
            let dropped = pointerInputs.removeFirst()
            // The log holds every input only after the dropped one.
            if let since = pointerLogSince {
                pointerLogSince = max(since, dropped.uptime)
            }
        }
    }

    /// The tap sees every pointer input from `uptime` on.
    func pointerTapEnabled(at uptime: Double) {
        lock.lock()
        pointerLogSince = uptime
        lock.unlock()
    }

    /// The tap stopped, so the log no longer knows every pointer input.
    func pointerTapDisabled() {
        lock.lock()
        pointerLogSince = nil
        lock.unlock()
    }

    /// Drops every record and the coverage start.
    private func clearLocked() {
        pointerInputs.removeAll()
        pointerLogSince = nil
        activations.removeAll()
    }

    /// `pid` became the frontmost app at `uptime`.
    func recordActivation(pid: pid_t, uptime: Double) {
        lock.lock()
        defer { lock.unlock() }
        activations.append(Activation(uptime: uptime, pid: pid))
        // The newest activation before the retention window still says which
        // app was in front at its start, so it stays.
        let cutoff = uptime - Self.retentionSeconds
        if let keepFrom = activations.lastIndex(where: { $0.uptime <= cutoff }), keepFrom > 0 {
            activations.removeFirst(keepFrom)
        }
        if activations.count > Self.maxActivations {
            activations.removeFirst(activations.count - Self.maxActivations)
        }
    }

    private func pruneLocked(now: Double) {
        let cutoff = now - Self.retentionSeconds
        if let keepFrom = pointerInputs.firstIndex(where: { $0.uptime >= cutoff }) {
            if keepFrom > 0 { pointerInputs.removeFirst(keepFrom) }
        } else {
            pointerInputs.removeAll()
        }
    }

    /// A copy of what the log holds now.
    public func snapshot() -> Snapshot {
        lock.lock()
        let pointer = pointerInputs
        let since = pointerLogSince
        let history = activations
        lock.unlock()
        return Snapshot(
            pointerInputs: pointer,
            pointerLogSince: since,
            frontmostAt: { uptime in
                // Nil before the first notice: the log does not know.
                history.last { $0.uptime <= uptime }?.pid
            }
        )
    }

    // MARK: Event filter

    static let pointerTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

    /// Whether the tap keeps an event: a mouse down or scroll from an input
    /// device. The plugin marks its own events, and an event that any
    /// process posted carries that process's pid, so neither is kept.
    static func shouldRecord(type: CGEventType, sourcePid: Int64, userData: Int64) -> Bool {
        pointerTypes.contains(type)
            && userData != kPaseoSyntheticEventUserData
            && UserInputEscapeMonitor.isHardwarePointerEvent(sourcePid: sourcePid)
    }

    // MARK: Live

    /// Starts the activation observer and the pointer tap. Called on the main
    /// thread when an agent takes control. The pause check needs input from
    /// before an action; for the first `UserActivity.pauseSeconds` after a
    /// start the log does not cover the whole window, so `UserActivity` uses
    /// the frontmost app rule. When the tap cannot be created the log has no
    /// pointer records and `UserActivity` uses the same rule.
    @MainActor
    public func start() {
        guard !started else { return }
        started = true

        lock.lock()
        tapGeneration += 1
        let generation = tapGeneration
        activeTapGeneration = generation
        lock.unlock()

        let workspace = NSWorkspace.shared
        if let front = workspace.frontmostApplication {
            recordActivation(pid: front.processIdentifier, uptime: ProcessInfo.processInfo.systemUptime)
        }
        // Posted on the main thread, so a stop on the main thread removes it
        // before any later notice can arrive.
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recordActivation(pid: app.processIdentifier, uptime: ProcessInfo.processInfo.systemUptime)
        }

        let thread = Thread { [weak self] in self?.runPointerTap(generation: generation) }
        thread.name = "paseo.computer-use.input-log"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the activation observer and the pointer tap, and drops every
    /// record. Called on the main thread when control ends. Safe to call when
    /// the log is not running.
    @MainActor
    public func stop() {
        if started {
            started = false
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
        }
        lock.lock()
        activeTapGeneration = nil
        let tap = eventTap
        let runLoop = tapRunLoop
        eventTap = nil
        tapRunLoop = nil
        clearLocked()
        lock.unlock()
        // Outside the lock: the tap callback takes the lock. An invalid port
        // also removes its source, so a tap thread that has not entered its
        // run loop yet returns from it at once.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private func runPointerTap(generation: Int) {
        let mask = Self.pointerTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                if let userInfo {
                    Unmanaged<UserInputLog>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        lock.lock()
        // The log stopped, or stopped and started again, while this thread
        // was starting.
        guard activeTapGeneration == generation else {
            lock.unlock()
            CFMachPortInvalidate(tap)
            return
        }
        eventTap = tap
        tapRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        pointerLogSince = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        CFRunLoopRun()
    }

    /// The on-screen windows that contain `location`, frontmost first, from a
    /// window list at most `windowListReuseSeconds` old. Runs on the tap
    /// thread only.
    func windows(at location: CGPoint, uptime: Double) -> [UserActivity.ScreenWindow] {
        let list: [UserActivity.ScreenWindow]
        if let cached = windowList, uptime - cached.uptime < Self.windowListReuseSeconds, uptime >= cached.uptime {
            list = cached.windows
        } else {
            list = readWindows()
            windowList = (uptime, list)
        }
        return list.filter { $0.bounds.contains(location) }
    }

    /// Runs on the tap thread only.
    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Input was missed while the tap was off, so coverage starts
            // again from now. A stopped log stays stopped.
            lock.lock()
            pointerLogSince = nil
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                pointerLogSince = ProcessInfo.processInfo.systemUptime
            }
            lock.unlock()
            return
        }
        guard Self.shouldRecord(
            type: type,
            sourcePid: event.getIntegerValueField(.eventSourceUnixProcessID),
            userData: event.getIntegerValueField(.eventSourceUserData)
        ) else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let location = event.location
        recordLivePointer(at: location, uptime: uptime, windows: windows(at: location, uptime: uptime))
    }
}
