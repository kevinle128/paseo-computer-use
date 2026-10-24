import Foundation

/// Cancellation state for one helper command.
///
/// Commands run on a worker thread, while `cancel` requests and the Escape
/// tap arrive on other threads. Long work (typing, drags, settle waits, the
/// accessibility walk) polls the token so a cancel stops it within a few
/// milliseconds instead of after the whole action.
public final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    /// How often a cancellable sleep wakes up to check the token.
    public static let pollMicros: UInt32 = 5_000

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func check() throws {
        if isCancelled {
            throw HelperError(
                code: HelperError.abortedByUser,
                message: "The command was cancelled before it finished."
            )
        }
    }

    /// Sleeps in short steps and throws as soon as the token is cancelled.
    public func sleep(micros: UInt32) throws {
        var remaining = micros
        try check()
        while remaining > 0 {
            let step = min(remaining, Self.pollMicros)
            usleep(step)
            remaining -= step
            try check()
        }
    }

    // MARK: - Token of the command running on this thread

    private static let threadKey = "PaseoCommandCancellation"

    /// The token of the command that runs on the calling thread, if any.
    /// Code that has no token (for example a unit test) is never cancelled.
    public static var current: CommandCancellation? {
        Thread.current.threadDictionary[threadKey] as? CommandCancellation
    }

    /// Runs `body` with `token` as the current token of this thread.
    public static func run<T>(with token: CommandCancellation, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[threadKey]
        dictionary[threadKey] = token
        defer { dictionary[threadKey] = previous }
        return try body()
    }

    /// Throws if the current command was cancelled.
    public static func checkCurrent() throws {
        try current?.check()
    }

    /// Cancellable sleep for the current command; a plain sleep without one.
    public static func sleepCurrent(micros: UInt32) throws {
        if let token = current {
            try token.sleep(micros: micros)
        } else {
            usleep(micros)
        }
    }
}

/// Runs overlay work on the main thread without waiting for it. The overlay
/// is AppKit UI, and the command thread must never block on the main thread.
public func runOnMainAsync(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated(body)
    }
}

/// Runs work on the main thread and returns its result. Use only for short
/// reads that AppKit or the input source APIs require on the main thread.
public func runOnMainSync<T>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated(body)
    }
}
