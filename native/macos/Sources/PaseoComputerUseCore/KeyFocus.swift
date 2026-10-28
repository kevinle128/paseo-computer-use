import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Live reads of who holds the keyboard, and the one write that puts the
/// user's window back on top of its app. The focus correction uses them; its
/// decisions are made in `FocusWatch` and `FocusCorrection`, which tests drive
/// with fakes.
///
/// Requests to one app can block, and some of these run on the main thread,
/// so each app element gets a short messaging timeout of its own. The
/// system-wide element is never given one: a timeout set on it applies to
/// every element of the process. Its read runs on a queue of its own instead,
/// and the caller waits for it only a short time (`boundedHolderPid`).
public enum KeyFocus {
    /// How long one request to an app may block here.
    static let appTimeoutSeconds: Float = 0.1
    /// How long a caller waits for the system-wide read of the key holder.
    static let holderWaitSeconds: Double = 0.05

    /// `holderPid` on its own queue, waited for at most `holderWaitSeconds`.
    static let boundedHolder = BoundedRead<pid_t>(
        queue: DispatchQueue(label: "paseo.computer-use.key-holder", qos: .userInteractive),
        wait: holderWaitSeconds,
        read: holderPid
    )

    /// The process the keyboard goes to now, or nil when the read did not
    /// answer within `holderWaitSeconds` or an earlier read still runs. Nil
    /// means not known, and no correction is made on it.
    public static func boundedHolderPid() -> pid_t? {
        boundedHolder.read()
    }

    /// What the guard knows about the user's keyboard focus when an action
    /// starts.
    public struct AtStart: Equatable, Sendable {
        /// The key window of the user's app: its focused window, else its
        /// topmost window on screen. Nil when neither is known.
        public let windowId: Int?
        /// The keyboard went to the user's app (the frontmost app) at the
        /// action start. When it did not, the watch does not give key focus
        /// back, because it does not know where the keys belonged.
        public let userHoldsKeys: Bool

        public init(windowId: Int?, userHoldsKeys: Bool) {
            self.windowId = windowId
            self.userHoldsKeys = userHoldsKeys
        }

        public static let unknown = AtStart(windowId: nil, userHoldsKeys: false)
    }

    /// The process the keyboard goes to now: the focused application of the
    /// system-wide element. It differs from the frontmost app while a window
    /// of another process holds the keys without bringing its app forward.
    public static func holderPid() -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedApplicationAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// The keyboard state of `app`, the frontmost app, before an action.
    public static func atStart(of app: FrontmostGuard.App) -> AtStart {
        AtStart(windowId: userWindowId(pid: app.pid), userHoldsKeys: boundedHolderPid() == app.pid)
    }

    private static func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, appTimeoutSeconds)
        return element
    }

    /// The window id of the app's focused window, else its topmost normal
    /// window on screen.
    static func userWindowId(pid: pid_t) -> Int? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value,
           CFGetTypeID(value) == AXUIElementGetTypeID(),
           let id = AXEngine.exactWindowId(of: value as! AXUIElement) {
            return id
        }
        return topWindowId(pid: pid)
    }

    /// The topmost normal (layer 0) window of `pid` on screen.
    static func topWindowId(pid: pid_t) -> Int? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return topWindowId(pid: pid, in: list)
    }

    /// The first normal window of `pid` in a front-to-back window list.
    static func topWindowId(pid: pid_t, in list: [[String: Any]]) -> Int? {
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int else {
                continue
            }
            return number
        }
        return nil
    }

    /// Raises the user's window with `AXRaise` when another window of its app
    /// is now above it. Returns true when it raised. It never activates an
    /// app; the user's app is already in front when this runs.
    public static func raiseIfBuried(pid: pid_t, windowId: Int) -> Bool {
        guard let top = topWindowId(pid: pid), top != windowId else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return false
        }
        for window in windows where AXEngine.exactWindowId(of: window) == windowId {
            AXUIElementSetMessagingTimeout(window, appTimeoutSeconds)
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        }
        return false
    }
}

/// Runs a read that can block on a queue of its own and waits for it only
/// `wait` seconds. A read that did not answer in time gives nil, and while it
/// still runs every later call gives nil at once without starting another,
/// so a hung app costs the caller one short wait and does not pile up reads.
final class BoundedRead<Value>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let wait: Double
    private let body: () -> Value?
    private let lock = NSLock()
    private var inFlight = false

    init(queue: DispatchQueue, wait: Double, read: @escaping () -> Value?) {
        self.queue = queue
        self.wait = wait
        self.body = read
    }

    /// The value, or nil when the read gave none, did not answer in time, or
    /// an earlier read still runs.
    func read() -> Value? {
        lock.lock()
        if inFlight {
            lock.unlock()
            return nil
        }
        inFlight = true
        lock.unlock()
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            answer.set(body())
            lock.lock()
            inFlight = false
            lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + wait) == .success else { return nil }
        return answer.value
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?

        func set(_ value: Value?) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: Value? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
