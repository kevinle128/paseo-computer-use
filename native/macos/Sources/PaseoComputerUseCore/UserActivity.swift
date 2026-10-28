import AppKit
import CoreGraphics
import Foundation

/// Refuses an action while the user is using the action's target app, so the
/// agent does not type or click into the middle of the user's own work there.
///
/// The agent is meant to work in a background app while the user keeps
/// working in their own app, so only input that went to the target counts.
/// Input to any other app, Paseo included (an approval click or Return), never
/// pauses an action on the target.
///
/// When the user acted comes from the hardware idle clocks
/// (`FocusWatch.hardwareIdleSeconds`, which reads only `.hidSystemState`):
/// the last key down, mouse button down, and scroll. These clocks need no
/// event tap, so they also see input from before the agent took the computer.
/// The plugin posts its events from a private event source to one process, so
/// they never reset these clocks. Pointer moves and drags do not count: a
/// person who reads on the Mac while the agent works moves the pointer all the
/// time. Input that software posts for the user (Voice Control, a remote
/// screen session) is not seen.
///
/// Where the input went:
/// - A key goes to the frontmost app. So a key down in the window counts when
///   the target is the frontmost app now, or was the frontmost app when the
///   key was pressed (`UserInputLog` keeps the activation times; for a key
///   from before the log started, only the frontmost app now counts). The
///   clock gives only the latest key, so an earlier key to the target
///   followed by a key to another app is not seen.
/// - A mouse down or a scroll goes to the window under the pointer, even when
///   that app is in the background. `UserInputLog` keeps the location of each
///   hardware mouse down and scroll with the on-screen windows at that place
///   when the input came, and a location counts when the frontmost of those
///   windows belongs to the target. The topmost window decides, not every
///   target window that contains the point: a click on a Paseo window that
///   covers the target went to Paseo. A record without its windows uses the
///   windows on screen at the check.
/// - When the log cannot account for the latest pointer input (its tap was not
///   running for the whole window, as in the first seconds after an agent
///   takes control, or it missed the event), or the frontmost
///   window at a location is not an app's (the menu bar strip belongs to the
///   window server and its clicks go to the frontmost app's menus), the
///   location is unknown and the pointer input counts only when the target is
///   the frontmost app now.
///
/// The check runs when a command starts, before the command sends anything.
/// Read commands are never refused.
public enum UserActivity {
    /// How long after the user's last key down, mouse down, or scroll in the
    /// target an action is refused. A first value, to tune with live
    /// measurements: meant to be long enough to cover the pause between two
    /// keys or clicks of a person at work, and short enough that an agent that
    /// waits a few seconds and reads again can go on.
    public static let pauseSeconds: Double = 3.0

    /// How much older than the clock's latest pointer input the log's latest
    /// record may be and still be the same event. The log takes its time in
    /// the tap callback, a moment after the event.
    public static let logToleranceSeconds: Double = 0.25

    /// The helper commands that send input or change an element.
    public static let gatedCommands: Set<String> = [
        "click",
        "drag",
        "scroll",
        "press_key",
        "type_text",
        "paste_text",
        "set_value",
        "select_text",
        "perform_secondary_action",
    ]

    /// What the agent reads. It has no idle numbers; those go to the audit
    /// log through `HelperError.userActivityDetail`.
    public static func message(appName: String) -> String {
        "The user is using \(appName). Wait a few seconds, call get_app_state again, then retry."
    }

    /// Seconds since the user's last input of each kind that counts.
    /// `.infinity` means never.
    public struct Idle: Equatable, Sendable {
        public let keyDown: Double
        /// The latest left, right, or other mouse button down.
        public let mouseDown: Double
        public let scroll: Double

        public init(keyDown: Double, mouseDown: Double, scroll: Double) {
            self.keyDown = keyDown
            self.mouseDown = mouseDown
            self.scroll = scroll
        }

        /// Seconds since the latest mouse down or scroll.
        public var pointer: Double { min(mouseDown, scroll) }
    }

    /// One hardware mouse down or scroll, with the uptime at which the log
    /// saw it and its location in global display coordinates (top-left
    /// origin, the same space as `kCGWindowBounds`).
    public struct PointerInput: Equatable, Sendable {
        public let uptime: Double
        public let location: CGPoint
        /// The on-screen windows that contained the location when the input
        /// came, frontmost first. Nil when they were not read.
        public let windows: [ScreenWindow]?

        public init(uptime: Double, location: CGPoint, windows: [ScreenWindow]? = nil) {
            self.uptime = uptime
            self.location = location
            self.windows = windows
        }
    }

    /// An on-screen window and its owner.
    public struct ScreenWindow: Equatable, Sendable {
        public let pid: pid_t
        public let bounds: CGRect
        /// Whether the owner is an app. A window of a system process (the
        /// menu bar strip of the window server) does not say which app got
        /// the input.
        public let isApp: Bool

        public init(pid: pid_t, bounds: CGRect, isApp: Bool = true) {
            self.pid = pid
            self.bounds = bounds
            self.isApp = isApp
        }
    }

    /// Everything one check reads, at one moment.
    public struct Observation {
        /// The system uptime of the check.
        public var now: Double
        public var idle: Idle
        /// The frontmost app now.
        public var frontmost: pid_t?
        /// The frontmost app at an earlier uptime, nil when not known.
        public var frontmostAt: (Double) -> pid_t?
        /// The mouse downs and scrolls the log kept, oldest first.
        public var pointerInputs: [PointerInput]
        /// The uptime since which the log has seen every hardware mouse down
        /// and scroll. Nil when its tap is not running.
        public var pointerLogSince: Double?
        /// The on-screen windows, frontmost first. Read only when needed.
        public var windows: () -> [ScreenWindow]

        public init(
            now: Double,
            idle: Idle,
            frontmost: pid_t?,
            frontmostAt: @escaping (Double) -> pid_t? = { _ in nil },
            pointerInputs: [PointerInput] = [],
            pointerLogSince: Double? = nil,
            windows: @escaping () -> [ScreenWindow] = { [] }
        ) {
            self.now = now
            self.idle = idle
            self.frontmost = frontmost
            self.frontmostAt = frontmostAt
            self.pointerInputs = pointerInputs
            self.pointerLogSince = pointerLogSince
            self.windows = windows
        }
    }

    /// Which rule found the user's input in the target. The audit log keeps
    /// it so live QA can tell the rules apart.
    public enum Reason: String, Equatable, Sendable {
        /// A key down in the window while the target is the frontmost app.
        case keyFrontmost = "key_frontmost"
        /// A key down in the window when the target was the frontmost app.
        case keyWasFrontmost = "key_was_frontmost"
        /// A mouse down or scroll in the window over a window of the target.
        case pointerWindow = "pointer_window"
        /// A mouse down or scroll in the window at a place the log does not
        /// know, while the target is the frontmost app.
        case pointerFrontmost = "pointer_frontmost"
    }

    /// The frontmost window that contains `point`, nil when none.
    public static func window(at point: CGPoint, in windows: [ScreenWindow]) -> ScreenWindow? {
        windows.first { $0.bounds.contains(point) }
    }

    /// The rule by which the user's recent input went to `target`, or nil
    /// when it went elsewhere or there was none in the window.
    public static func decide(target: pid_t, _ seen: Observation) -> Reason? {
        let idle = seen.idle
        if idle.keyDown < pauseSeconds {
            if seen.frontmost == target {
                return .keyFrontmost
            }
            if seen.frontmostAt(seen.now - idle.keyDown) == target {
                return .keyWasFrontmost
            }
        }

        guard idle.pointer < pauseSeconds else { return nil }
        let recent = seen.pointerInputs.filter { seen.now - $0.uptime < pauseSeconds }
        var hitNonApp = false
        if !recent.isEmpty {
            // The windows at the check, read once and only for a record that
            // has no windows of its own.
            var windowsNow: [ScreenWindow]?
            for input in recent {
                let windows: [ScreenWindow]
                if let atInput = input.windows {
                    windows = atInput
                } else {
                    let read = windowsNow ?? seen.windows()
                    windowsNow = read
                    windows = read
                }
                guard let hit = window(at: input.location, in: windows) else { continue }
                if !hit.isApp {
                    hitNonApp = true
                } else if hit.pid == target {
                    return .pointerWindow
                }
            }
        }
        // The log knows where the latest pointer input went only when its
        // tap ran for the whole window and it holds a record of that input.
        let coveredWindow = seen.pointerLogSince.map { $0 <= seen.now - pauseSeconds } ?? false
        let sawLatest = recent.last.map { seen.now - $0.uptime <= idle.pointer + logToleranceSeconds } ?? false
        if hitNonApp || !(coveredWindow && sawLatest), seen.frontmost == target {
            return .pointerFrontmost
        }
        return nil
    }

    /// The audit text of a refusal.
    static func detail(_ reason: Reason, _ idle: Idle) -> String {
        func s(_ value: Double) -> String { String(format: "%.3fs", value) }
        return "user_active: rule=\(reason.rawValue) key_down_idle=\(s(idle.keyDown))"
            + " mouse_down_idle=\(s(idle.mouseDown)) scroll_idle=\(s(idle.scroll)) pause=\(s(pauseSeconds))"
    }

    /// Reads the idle times from the hardware clocks. `clock` gives the
    /// seconds since the last event of one type on one event source state;
    /// tests pass a fake one.
    public static func idle(
        clock: (CGEventSourceStateID, CGEventType) -> Double = CGEventSource.secondsSinceLastEventType
    ) -> Idle {
        func hardware(_ type: CGEventType) -> Double {
            FocusWatch.hardwareIdleSeconds(type, clock: clock)
        }
        return Idle(
            keyDown: hardware(.keyDown),
            mouseDown: FocusWatch.InputIdle.mouseDownTypes.map(hardware).min() ?? .infinity,
            scroll: hardware(.scrollWheel)
        )
    }

    /// The on-screen windows that can take a click, frontmost first, from a
    /// `CGWindowListCopyWindowInfo` list. The helper's own windows (the
    /// overlay lets clicks through) and fully clear windows are left out.
    /// `isApp` tells an app's process from a system process.
    static func screenWindows(_ infoList: [[String: Any]], ownPid: pid_t, isApp: (pid_t) -> Bool) -> [ScreenWindow] {
        var appByPid: [pid_t: Bool] = [:]
        return infoList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPid,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  !bounds.isEmpty else {
                return nil
            }
            let app = appByPid[pid] ?? isApp(pid)
            appByPid[pid] = app
            return ScreenWindow(pid: pid, bounds: bounds, isApp: app)
        }
    }

    static func liveScreenWindows() -> [ScreenWindow] {
        let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return screenWindows(
            infoList,
            ownPid: ProcessInfo.processInfo.processIdentifier,
            isApp: { NSRunningApplication(processIdentifier: $0) != nil }
        )
    }

    /// What the helper sees now: the hardware clocks, the frontmost app, and
    /// the shared input log.
    public static func liveObservation() -> Observation {
        let now = ProcessInfo.processInfo.systemUptime
        let log = UserInputLog.shared.snapshot()
        return Observation(
            now: now,
            idle: idle(),
            frontmost: FrontmostGuard.frontmost()?.pid,
            frontmostAt: log.frontmostAt,
            pointerInputs: log.pointerInputs,
            pointerLogSince: log.pointerLogSince,
            windows: liveScreenWindows
        )
    }

    public static func liveAppName(_ pid: pid_t) -> String {
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.localizedName ?? app?.bundleIdentifier ?? "the app"
    }

    /// Throws `user_active` when `command` sends input or changes an element
    /// and the user's input went to `target` within `pauseSeconds`. Nothing
    /// is read for any other command, or when the target is not known (the
    /// command then reports its own error).
    public static func check(
        command: String,
        target: pid_t?,
        observe: () -> Observation = { liveObservation() },
        appName: (pid_t) -> String = { liveAppName($0) }
    ) throws {
        guard gatedCommands.contains(command), let target else { return }
        let seen = observe()
        guard let reason = decide(target: target, seen) else { return }
        throw HelperError(
            code: HelperError.userActive,
            message: message(appName: appName(target)),
            userActivityDetail: detail(reason, seen.idle)
        )
    }
}
