import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Looks up functions the system exports but its SDK does not declare. A
/// missing symbol gives nil, and every caller then takes its public path or
/// skips the step; no caller may crash or block on a missing symbol.
enum PrivateSymbol {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    static func address(_ name: String) -> UnsafeMutableRawPointer? {
        if let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
            return address
        }
        if let skyLight, let address = dlsym(skyLight, name) {
            return address
        }
        return nil
    }
}

/// Runs the helper's private window server calls one at a time.
///
/// These calls do not say that they are safe from two threads at once, and
/// the helper makes them from the main thread (front process reads, the
/// correction), from the command thread (the synthetic activation and key
/// window records of each action), and from the screen hold watchdog. Each
/// call takes this lock for its own length only: no caller holds it across
/// other work, a wait for another thread, or a second locked call, so the
/// watchdog waits at most for one window server call that is in flight.
public final class WindowServerCalls: @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    public func run<T>(_ call: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try call()
    }
}

/// The window server calls that read and move the front process and hold
/// screen updates. Each one is optional: `nil` or `false` means the call is
/// missing or refused, and the caller falls back to the public API. Every
/// call goes through `calls`.
public final class WindowServer: @unchecked Sendable {
    public static let shared = WindowServer()

    /// The one lock of every private window server call of the helper,
    /// `InputDriver`'s event records included.
    static let calls = WindowServerCalls()

    private typealias FrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private typealias PidForProcessFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> Int32
    private typealias ProcessForPidFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private typealias SetFrontProcessFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias UpdateFn = @convention(c) (Int32) -> Int32

    private let frontProcessFn: FrontProcessFn?
    private let pidForProcessFn: PidForProcessFn?
    private let processForPidFn: ProcessForPidFn?
    private let setFrontProcessFn: SetFrontProcessFn?
    private let connectionFn: ConnectionFn?
    private let holdUpdatesFn: UpdateFn?
    private let releaseUpdatesFn: UpdateFn?

    /// The option of the front process request that marks it as made by the
    /// user. With a window id, the window server then brings that window of
    /// the process forward; the key window records that follow make it key.
    /// Only a focus correction sends this request, to bring the user's window
    /// back to the front after the target app took it.
    static let userMadeFrontRequest: UInt32 = 0x200

    init() {
        func load<T>(_ name: String, as type: T.Type) -> T? {
            PrivateSymbol.address(name).map { unsafeBitCast($0, to: type) }
        }
        frontProcessFn = load("_SLPSGetFrontProcess", as: FrontProcessFn.self)
        pidForProcessFn = load("GetProcessPID", as: PidForProcessFn.self)
        processForPidFn = load("GetProcessForPID", as: ProcessForPidFn.self)
        setFrontProcessFn = load("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
        connectionFn = load("SLSMainConnectionID", as: ConnectionFn.self)
        holdUpdatesFn = load("SLSDisableUpdate", as: UpdateFn.self)
        releaseUpdatesFn = load("SLSReenableUpdate", as: UpdateFn.self)
    }

    /// The pid of the process the window server has in front, or nil when the
    /// call is missing or fails. It changes the moment an app comes to the
    /// front, before AppKit's frontmost app follows.
    public func frontPid() -> pid_t? {
        guard let frontProcessFn, let pidForProcessFn else { return nil }
        return Self.calls.run {
            var psn = ProcessSerialNumber()
            guard frontProcessFn(&psn) == 0 else { return nil }
            var pid: pid_t = 0
            guard pidForProcessFn(&psn, &pid) == 0, pid > 0 else { return nil }
            return pid
        }
    }

    /// Asks the window server to bring `windowId` of `pid` to the front. False
    /// when the call is missing or the window server refused; true means only
    /// that the request was accepted.
    public func requestFront(pid: pid_t, windowId: Int) -> Bool {
        guard windowId > 0, let setFrontProcessFn, let processForPidFn else { return false }
        return Self.calls.run {
            var psn = ProcessSerialNumber()
            guard processForPidFn(pid, &psn) == 0 else { return false }
            return setFrontProcessFn(&psn, UInt32(truncatingIfNeeded: windowId), Self.userMadeFrontRequest) == 0
        }
    }

    /// The hold and release of screen updates on this process's window server
    /// connection, or nil when either call is missing.
    func screenUpdatePrimitives() -> ScreenUpdateGate.Primitives? {
        guard let connectionFn, let holdUpdatesFn, let releaseUpdatesFn else { return nil }
        let connection = Self.calls.run { connectionFn() }
        return Self.serializedPrimitives(
            hold: { holdUpdatesFn(connection) == 0 },
            release: { _ = releaseUpdatesFn(connection) },
            calls: Self.calls
        )
    }

    /// The hold and the release, each made under `calls`, so the watchdog's
    /// release never runs at the same time as another window server call.
    static func serializedPrimitives(
        hold: @escaping () -> Bool,
        release: @escaping () -> Void,
        calls: WindowServerCalls
    ) -> ScreenUpdateGate.Primitives {
        ScreenUpdateGate.Primitives(
            hold: { calls.run(hold) },
            release: { calls.run(release) }
        )
    }
}
