import AppKit
import Foundation

/// Watches which app is in front around an action that changes something. The
/// plugin must not take the user's focus. A change that shows right after the
/// action is reported in its result. After the settle wait a `FocusWatch`
/// keeps looking for a short time and gives focus back to the app that had it
/// before the action when the action caused the change; what it did is
/// reported in the result of the action when the watch ended during the settle
/// wait, else in the next result of the same caller.
///
/// Commands run one at a time on `commandQueue`. The watch ends on the main
/// thread, so the state it shares with the commands sits behind a lock.
public final class FrontmostGuard {
    public struct App: Equatable, Sendable {
        public let pid: pid_t
        /// The bundle id, else the name: what the line prints.
        public let label: String
        /// The name a person knows the app by.
        public let name: String

        public init(pid: pid_t, label: String, name: String? = nil) {
            self.pid = pid
            self.label = label
            self.name = name ?? label
        }
    }

    /// The guard of the helper process.
    public static let shared = FrontmostGuard(startWatch: FocusWatch.live, readKeyFocus: KeyFocus.atStart)

    /// What a watch needs to know about the action it follows.
    public struct WatchRequest: Sendable {
        /// The app in front before the action.
        public let previous: App
        /// The app the action was aimed at, when known.
        public let targetPid: pid_t?
        /// The start of the action on the system uptime clock, and as a date
        /// (to tell a process the action launched from an older one).
        public let actionStart: Double
        public let actionDate: Date
        /// Command, Control, or Option was held on an input device when the
        /// action started, so a Command+Tab that ends during the watch is seen.
        public let switchModifierAtStart: Bool
        /// The user's key window and whether the keyboard was with the user's
        /// app when the action started.
        public let keyFocus: KeyFocus.AtStart
        /// The action sends keys (`press_key`, `type_text`, `paste_text`), so
        /// it posts the key window records to the target itself.
        public let isKeyboardAction: Bool

        public init(
            previous: App,
            targetPid: pid_t?,
            actionStart: Double,
            actionDate: Date,
            switchModifierAtStart: Bool = false,
            keyFocus: KeyFocus.AtStart = .unknown,
            isKeyboardAction: Bool = false
        ) {
            self.previous = previous
            self.targetPid = targetPid
            self.actionStart = actionStart
            self.actionDate = actionDate
            self.switchModifierAtStart = switchModifierAtStart
            self.keyFocus = keyFocus
            self.isKeyboardAction = isKeyboardAction
        }
    }

    /// Starts a watch for an action. `finish` gets the result, or nil when
    /// nothing happened.
    public typealias StartWatch = (_ request: WatchRequest, _ finish: @escaping (FocusWatch.Result?) -> Void) -> FocusWatch

    /// Result key and audit text for a changed frontmost app.
    public static let resultKey = "userFocusChanged"
    /// Result key for the input idle times behind a watch outcome. The plugin
    /// writes it to the audit log only, never to the agent's text.
    public static let detailKey = "focusWatchDetail"

    /// How long to wait after the action for an activation the app started
    /// itself (a press that opens a window can activate it a moment later).
    static let settleMicros: UInt32 = 60_000

    /// The app in front when the last guarded command ended. An activation
    /// that comes after the settle wait shows up as the difference from the
    /// next command's first read. `lastAfter` is that read, nil when no
    /// regular app was in front; `lastKnown` is the last read before or
    /// after a command that found one, so a switch made while a launcher was
    /// in front is still reported at the next command.
    private var lastAfter: App?
    private var lastKnown: App?
    private var hasRun = false
    /// Lines from watches that ended after their action returned, with the
    /// caller whose action caused each and the audit detail of the watch. A
    /// line is shown to that caller only.
    private var pendingLines: [(caller: String?, line: String, detail: String?)] = []
    /// More lines than this means callers that never came back; the oldest go.
    static let maxPendingLines = 8
    private var watch: FocusWatch?
    /// Bumped by every stop (Escape, takeover, end of turn, tap release). An
    /// action that began before a stop never starts a watch.
    private var stopGeneration = 0
    private let lock = NSLock()
    private let startWatch: StartWatch?
    private let readKeyFocus: (App) -> KeyFocus.AtStart

    /// A guard with no `startWatch` only reports; it never touches focus.
    /// `readKeyFocus` reads the user's key window before each action; it is
    /// read only when a watch can start.
    public init(startWatch: StartWatch? = nil, readKeyFocus: @escaping (App) -> KeyFocus.AtStart = { _ in .unknown }) {
        self.startWatch = startWatch
        self.readKeyFocus = readKeyFocus
    }

    /// Stops every watch, and every action that began before this call will
    /// not start one. Called for Escape, a takeover, the end of a turn, and the
    /// release of the stop key. It returns after the watch has stopped. An
    /// activation that was already requested cannot be taken back, so the
    /// watch then reports that the restore may still apply.
    public func stopWatches() {
        lock.lock()
        stopGeneration += 1
        lock.unlock()
        endWatch()
    }

    private func endWatch() {
        lock.lock()
        let current = watch
        watch = nil
        lock.unlock()
        guard let current else { return }
        runOnMainSync {
            current.cancel()
            current.tick()
        }
    }

    /// How long a new action waits for a restore the previous watch already
    /// asked for. A new watch must not see the restored app arrive and take
    /// it for a change to undo.
    static let restoreSettleSeconds: Double = FocusWatch.confirmSeconds + 0.2

    /// Ends the previous action's watch. A watch with an activation in flight
    /// is given time to see it land first.
    private func settlePreviousWatch() {
        lock.lock()
        let current = watch
        lock.unlock()
        if let current, current.isRestoring {
            let deadline = ProcessInfo.processInfo.systemUptime + Self.restoreSettleSeconds
            while current.isRestoring, ProcessInfo.processInfo.systemUptime < deadline {
                usleep(10_000)
            }
        }
        endWatch()
    }

    private func currentStopGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stopGeneration
    }

    private func beginWatch(_ request: WatchRequest?, caller: String?, generation: Int) {
        guard let startWatch, let request else { return }
        // A command that was cancelled (Escape, a stop of the caller's turn)
        // or a stop that came after the action started leaves nothing to undo.
        if CommandCancellation.current?.isCancelled == true || currentStopGeneration() != generation {
            return
        }
        let started = startWatch(request) { [weak self] result in
            self?.watchEnded(result, caller: caller)
        }
        lock.lock()
        watch = started
        let stopped = stopGeneration != generation
        lock.unlock()
        // A stop that came while the watch was being made.
        if stopped { endWatch() }
    }

    private func watchEnded(_ result: FocusWatch.Result?, caller: String?) {
        guard let result, let line = result.line else { return }
        lock.lock()
        pendingLines.append((caller, line, result.detail))
        if pendingLines.count > Self.maxPendingLines {
            pendingLines.removeFirst(pendingLines.count - Self.maxPendingLines)
        }
        // What is in front now, so the next command does not report it again.
        lastAfter = result.frontAfter
        lastKnown = result.frontAfter
        lock.unlock()
    }

    private func takePendingLines(for caller: String?) -> (lines: [String], details: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let mine = pendingLines.filter { $0.caller == caller }
        pendingLines.removeAll { $0.caller == caller }
        return (mine.map(\.line), mine.compactMap(\.detail))
    }

    /// The two readers of the app in front.
    ///
    /// `confirmed` is AppKit's frontmost app. It is the only answer any
    /// decision uses: the reads before and after an action, the user's
    /// keyboard at the action start, the user activity pause, and every
    /// outcome of a watch. `detected` is the window server's front process,
    /// which changes the moment an app comes forward, before AppKit follows.
    /// The plugin posts window server records to the target on each action,
    /// and live QA has not shown that they leave the window server's front
    /// process alone, so `detected` only tells a watch where to look sooner.
    ///
    /// Only regular apps (the ones with a Dock icon and a menu bar) count as
    /// the app in front. A system panel (Spotlight, Control Center) or another
    /// background process gives nil from `confirmed` and the AppKit answer
    /// from `detected`.
    public struct FrontReader {
        let windowServerPid: () -> pid_t?
        let workspacePid: () -> pid_t?
        let app: (pid_t) -> App?

        public init(
            windowServerPid: @escaping () -> pid_t?,
            workspacePid: @escaping () -> pid_t?,
            app: @escaping (pid_t) -> App?
        ) {
            self.windowServerPid = windowServerPid
            self.workspacePid = workspacePid
            self.app = app
        }

        /// AppKit's frontmost app, when it is a regular app.
        public func confirmed() -> App? {
            workspacePid().flatMap(app)
        }

        /// The window server's front process when it is a regular app, else
        /// `confirmed()`.
        public func detected() -> App? {
            if let pid = windowServerPid(), let app = app(pid) {
                return app
            }
            return confirmed()
        }

        /// AppKit updates `frontmostApplication` on the main thread and does
        /// not promise a read from another thread is safe, so every read goes
        /// there. No command running on the main thread waits for the command
        /// queue, so the wait cannot deadlock.
        static let live = FrontReader(
            windowServerPid: { WindowServer.shared.frontPid() },
            workspacePid: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            app: { FrontmostGuard.app(pid: $0) }
        )
    }

    /// AppKit's frontmost app (`FrontReader.confirmed`), read on the main
    /// thread. The guard, the user's keyboard baseline, and the user activity
    /// pause use it.
    public static func frontmost() -> App? {
        runOnMainSync { FrontReader.live.confirmed() }
    }

    /// The window server's front process, else AppKit's frontmost app
    /// (`FrontReader.detected`), read on the main thread. A watch uses it
    /// only to see a change sooner; see `FocusWatch`.
    public static func windowServerFront() -> App? {
        runOnMainSync { FrontReader.live.detected() }
    }

    /// The running regular app with this pid, or nil when no regular app has
    /// it.
    static func app(pid: pid_t) -> App? {
        guard let running = NSRunningApplication(processIdentifier: pid),
              !running.isTerminated,
              running.activationPolicy == .regular else {
            return nil
        }
        let pid = running.processIdentifier
        return App(
            pid: pid,
            label: running.bundleIdentifier ?? running.localizedName ?? "pid \(pid)",
            name: running.localizedName ?? running.bundleIdentifier ?? "pid \(pid)"
        )
    }

    /// The words before the apps in a line about the keyboard focus.
    static let keyFocusSubject = "key focus "

    /// `user_focus_changed: <old> -> <new>` when the frontmost app differs, else nil.
    /// Two instances of one app share a bundle id, so then each side prints
    /// its name and pid. `subject` comes before the apps: the keyboard focus
    /// lines say `key focus`. Nil also when either side is nil: with no
    /// regular app in front (a launcher such as Alfred, a system panel) the
    /// user's app is unknown, and `unknownFront` records the change for the
    /// audit log only.
    static func change(before: App?, after: App?, subject: String = "", suffix: String = "") -> String? {
        guard let before, let after, before.pid != after.pid else { return nil }
        let sameLabel = before.label == after.label
        func describe(_ app: App) -> String {
            sameLabel ? "\(app.name) (pid \(app.pid))" : app.label
        }
        return "user_focus_changed: \(subject)\(describe(before)) -> \(describe(after))\(suffix)"
    }

    /// `front_app_unknown: <old> -> <new>` for the audit log when the app in
    /// front changed to or from no regular app, else nil. The agent gets no
    /// line for it.
    static func unknownFront(before: App?, after: App?, suffix: String = "") -> String? {
        guard before?.pid != after?.pid, before == nil || after == nil else { return nil }
        return "front_app_unknown: \(before?.label ?? "none") -> \(after?.label ?? "none")\(suffix)"
    }

    static let withinSettleSuffix = " (it appeared in the wait after the action and may not come from it)"

    static let sincePreviousSuffix = " (since the previous action)"

    /// Runs one action and adds the change lines to its result when the
    /// frontmost app is not the same afterwards, or was not the same as when
    /// the previous action ended. The settle wait never discards a finished
    /// action: a cancel that arrives during it is left for the next check.
    /// An action that throws carries the lines in its error.
    func run(
        caller: String? = nil,
        target: () -> pid_t? = { nil },
        keyboard: Bool = false,
        read: () -> App? = FrontmostGuard.frontmost,
        switchModifierHeld: () -> Bool = { FocusWatch.hardwareSwitchModifierHeld() },
        settle: () throws -> Void = { try CommandCancellation.sleepCurrent(micros: FrontmostGuard.settleMicros) },
        _ action: () throws -> [String: Any]
    ) throws -> [String: Any] {
        // The previous action's watch ends first: this action has its own.
        settlePreviousWatch()
        let actionStart = ProcessInfo.processInfo.systemUptime
        let actionDate = Date()
        let switchModifierAtStart = switchModifierHeld()
        let generation = currentStopGeneration()
        let targetPid = target()
        let before = read()
        // The user's key window, read before the action can move it.
        let keyFocus = startWatch == nil ? KeyFocus.AtStart.unknown : before.map(readKeyFocus) ?? .unknown
        func request() -> WatchRequest? {
            before.map { WatchRequest(
                previous: $0,
                targetPid: targetPid,
                actionStart: actionStart,
                actionDate: actionDate,
                switchModifierAtStart: switchModifierAtStart,
                keyFocus: keyFocus,
                isKeyboardAction: keyboard
            ) }
        }
        var (lines, details) = takePendingLines(for: caller)
        // A change between two known apps is a line for the agent; one to or
        // from no regular app is an audit detail only.
        func note(from: App?, to: App?, line: String?, suffix: String) {
            if let line {
                lines.append(line)
            } else if let detail = Self.unknownFront(before: from, after: to, suffix: suffix) {
                details.append(detail)
            }
        }
        if hasRun {
            let previous = lastAfterReads()
            note(
                from: previous.raw,
                to: before,
                line: Self.change(before: previous.known, after: before, suffix: Self.sincePreviousSuffix),
                suffix: Self.sincePreviousSuffix
            )
        }
        hasRun = true
        rememberKnown(before)
        var result: [String: Any]
        do {
            result = try action()
        } catch {
            let now = read()
            setLastAfter(now)
            note(from: before, to: now, line: Self.change(before: before, after: now), suffix: "")
            beginWatch(request(), caller: caller, generation: generation)
            throw Self.carrying(lines, details: details, in: error)
        }
        let immediately = read()
        // The watch runs during the settle wait, so a restore that completes
        // inside it is reported by this action. One that completes later is
        // kept for the next action of the same caller.
        beginWatch(request(), caller: caller, generation: generation)
        try? settle()
        if CommandCancellation.current?.isCancelled == true { endWatch() }
        let after = read()
        setLastAfter(after)
        let ended = takePendingLines(for: caller)
        lines.append(contentsOf: ended.lines)
        details.append(contentsOf: ended.details)
        // A change that only shows after the wait may be the user's own
        // switch, so the line says when it appeared.
        let late = immediately?.pid == before?.pid
        let suffix = late ? Self.withinSettleSuffix : ""
        note(from: before, to: after, line: Self.change(before: before, after: after, suffix: suffix), suffix: suffix)
        if !lines.isEmpty {
            result[Self.resultKey] = lines.joined(separator: "\n")
        }
        if !details.isEmpty {
            result[Self.detailKey] = details.joined(separator: "\n")
        }
        return result
    }

    private func setLastAfter(_ app: App?) {
        lock.lock()
        lastAfter = app
        if let app { lastKnown = app }
        lock.unlock()
    }

    private func rememberKnown(_ app: App?) {
        guard let app else { return }
        lock.lock()
        lastKnown = app
        lock.unlock()
    }

    private func lastAfterReads() -> (raw: App?, known: App?) {
        lock.lock()
        defer { lock.unlock() }
        return (lastAfter, lastKnown)
    }

    /// `run` on the guard of the helper process.
    public static func run(
        caller: String? = nil,
        target: () -> pid_t? = { nil },
        keyboard: Bool = false,
        read: () -> App? = FrontmostGuard.frontmost,
        _ action: () throws -> [String: Any]
    ) throws -> [String: Any] {
        try shared.run(caller: caller, target: target, keyboard: keyboard, read: read, action)
    }

    private static func carrying(_ lines: [String], details: [String], in error: Error) -> Error {
        guard !lines.isEmpty || !details.isEmpty else { return error }
        let note = lines.isEmpty ? nil : lines.joined(separator: "\n")
        let detail = details.isEmpty ? nil : details.joined(separator: "\n")
        if var helperError = error as? HelperError {
            helperError.userFocusChanged = note
            helperError.focusWatchDetail = detail
            return helperError
        }
        return HelperError(
            code: HelperError.internalError,
            message: error.localizedDescription,
            userFocusChanged: note,
            focusWatchDetail: detail
        )
    }
}
