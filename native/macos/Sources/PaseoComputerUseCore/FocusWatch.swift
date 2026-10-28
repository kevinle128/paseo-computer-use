import AppKit
import CoreGraphics
import Foundation

/// Watches the frontmost app, and who holds the keyboard, for a short time
/// after an action and gives them back when the action itself took them.
///
/// An app can activate itself some time after an action it received (a key
/// that opens a window, for example), later than the settle wait of
/// `FrontmostGuard` looks. Computer Use must never disturb the user's work, so
/// the watch corrects only when it can tell the change came from the action:
/// the app that took focus is the action's target, or a process that was
/// launched after the action started. Any other app taking focus is probably
/// the user's choice and is reported, not undone. It also does nothing when
/// the user gave hardware input that can switch apps (a key down or a release
/// with Command, Control, or Option held, or a mouse click) at a time that
/// could explain the change; `userActed` has the rule.
///
/// The window server's front process changes first, so it starts a look;
/// AppKit's frontmost app must agree before any outcome about the front (a
/// correction or a line). See `FrontmostGuard.FrontReader`.
///
/// Two things are corrected, at most one of them once per action:
/// - The target comes to the front. The watch sees it on two reads in a row,
///   AppKit agrees on the second, then `FocusCorrection.bringBack` holds screen updates, posts the
///   synthetic activation to the target again, brings the user's window back
///   to the front, and releases the hold.
/// - The user's app stays in front, but a window of the target takes the
///   keyboard. The watch sees it on two reads in a row, then
///   `FocusCorrection.returnKeyFocus` posts the key window records to the
///   user's window without activating the target. The window request follows
///   only when the keys stay with the target and the target also took the
///   front. This needs the user's window and the keyboard to have been with
///   the user's app when the action started. After a keyboard action it runs
///   only when the target holds the keys and AppKit says the user's app lost
///   the front.
/// The only app it ever activates is the one that was in front before the
/// action; the target is never activated, hidden, or deactivated.
///
/// `tick` does the work and has no timer, clock, or AppKit call of its own, so
/// tests drive it with fakes. `FocusWatch.live` runs it on the main thread,
/// every 20 ms and on each app activation notice.
public final class FocusWatch {
    public enum Outcome: Equatable, Sendable {
        case restored(afterMs: Int)
        case couldNotRestore
        case userSwitched
        /// An app that is neither the target nor a process the action
        /// launched took focus, so nothing was activated.
        case anotherAppTookFocus
        /// The watch was stopped after the activation was requested. The
        /// request cannot be taken back, so it may still take effect.
        case stoppedAfterRequest
        /// The user's app stayed in front, a window of the target (or of a
        /// process the action launched) took the keyboard, and the keys went
        /// back to the user's window.
        case keyFocusReturned(afterMs: Int)
        /// The keys were asked back but did not return in time, or could not
        /// be asked back.
        case couldNotReturnKeyFocus
        /// Hardware input explains the move of the keyboard, so it was kept.
        case userMovedKeyFocus
        /// The watch was stopped after the keys were asked back.
        case stoppedAfterKeyFocusRequest

        /// The outcome is about the keyboard; the frontmost app did not change.
        var isKeyFocus: Bool {
            switch self {
            case .keyFocusReturned, .couldNotReturnKeyFocus, .userMovedKeyFocus, .stoppedAfterKeyFocusRequest: return true
            case .restored, .couldNotRestore, .userSwitched, .anotherAppTookFocus, .stoppedAfterRequest: return false
            }
        }
    }

    public struct Result: Equatable, Sendable {
        public let previous: FrontmostGuard.App
        /// The app that took the front, or the keyboard for a key focus outcome.
        public let current: FrontmostGuard.App
        public let outcome: Outcome
        /// The input idle times of the check that decided the outcome. Nil
        /// when no input check was made (another app took focus).
        public let evidence: Evidence?
        /// The correction steps that ran. Nil when none ran.
        public let steps: FocusCorrection.Steps?

        public init(
            previous: FrontmostGuard.App,
            current: FrontmostGuard.App,
            outcome: Outcome,
            evidence: Evidence? = nil,
            steps: FocusCorrection.Steps? = nil
        ) {
            self.previous = previous
            self.current = current
            self.outcome = outcome
            self.evidence = evidence
            self.steps = steps
        }

        /// The app in front when the watch ended.
        public var frontAfter: FrontmostGuard.App {
            if case .restored = outcome { return previous }
            return outcome.isKeyFocus ? previous : current
        }

        /// The `user_focus_changed` line for the agent and the audit log.
        public var line: String? {
            let suffix: String
            switch outcome {
            case .restored(let ms): suffix = " (restored after \(ms) ms)"
            case .couldNotRestore: suffix = " (could not restore)"
            case .userSwitched: suffix = " (user switched apps)"
            case .anotherAppTookFocus: suffix = " (not restored: another app took focus)"
            case .stoppedAfterRequest: suffix = " (stopped; the restore may still apply)"
            case .keyFocusReturned(let ms): suffix = " (returned after \(ms) ms)"
            case .couldNotReturnKeyFocus: suffix = " (could not return)"
            case .userMovedKeyFocus: suffix = " (user moved the keyboard focus)"
            case .stoppedAfterKeyFocusRequest: suffix = " (stopped; the return may still apply)"
            }
            return FrontmostGuard.change(
                before: previous,
                after: current,
                subject: outcome.isKeyFocus ? FrontmostGuard.keyFocusSubject : "",
                suffix: suffix
            )
        }

        /// The idle times behind the outcome and the correction steps that
        /// ran, for the audit log only. Live QA reads it to tell real user
        /// input from a false positive; the agent does not get it.
        public var detail: String? {
            guard let evidence else { return nil }
            let name: String
            switch outcome {
            case .restored: name = "restored"
            case .couldNotRestore: name = "could_not_restore"
            case .userSwitched: name = "user_switched"
            case .anotherAppTookFocus: name = "another_app_took_focus"
            case .stoppedAfterRequest: name = "stopped_after_request"
            case .keyFocusReturned: name = "key_focus_returned"
            case .couldNotReturnKeyFocus: name = "could_not_return_key_focus"
            case .userMovedKeyFocus: name = "user_moved_key_focus"
            case .stoppedAfterKeyFocusRequest: name = "stopped_after_key_focus_request"
            }
            let correction = steps.map { " \($0.text)" } ?? ""
            return "focus_watch: \(name) \(evidence.text)\(correction)"
        }
    }

    /// Seconds since the last hardware event of the input kinds that can
    /// switch apps. `.infinity` means never.
    public struct InputIdle: Equatable, Sendable {
        /// Any key down: Command+Tab, an app shortcut, Return on a dialog.
        public let keyDown: Double
        /// Any modifier key press or release. Command+Tab switches when
        /// Command is released, so the Tab key down can come before the
        /// action started and the switch after it. The clock does not say
        /// which modifier it was; see `Evidence.switchModifierSeen`.
        public let flagsChanged: Double
        /// The latest left, right, or other mouse button down.
        public let mouseDown: Double
        /// The latest left, right, or other mouse button up. The Dock
        /// switches apps on the mouse up.
        public let mouseUp: Double

        public init(keyDown: Double, flagsChanged: Double = .infinity, mouseDown: Double, mouseUp: Double = .infinity) {
            self.keyDown = keyDown
            self.flagsChanged = flagsChanged
            self.mouseDown = mouseDown
            self.mouseUp = mouseUp
        }

        static let mouseDownTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        static let mouseUpTypes: [CGEventType] = [.leftMouseUp, .rightMouseUp, .otherMouseUp]

        /// Reads the idle times from a clock that gives the seconds since the
        /// last hardware event of one type.
        static func read(_ clock: (CGEventType) -> Double) -> InputIdle {
            InputIdle(
                keyDown: clock(.keyDown),
                flagsChanged: clock(.flagsChanged),
                mouseDown: mouseDownTypes.map(clock).min() ?? .infinity,
                mouseUp: mouseUpTypes.map(clock).min() ?? .infinity
            )
        }

        /// Seconds since the latest mouse button down or up.
        var mouse: Double { min(mouseDown, mouseUp) }
    }

    /// What one input check saw. Times are seconds after the action started.
    public struct Evidence: Equatable, Sendable {
        public let idle: InputIdle
        /// When the check was made.
        public let checkedAt: Double
        /// The earliest time the app that took focus can have come to the
        /// front: the last poll that saw another app, or the action start.
        public let frontFrom: Double
        /// Command, Control, or Option was held at the action start or at a
        /// poll since. The idle clocks do not say which modifier changed or
        /// which modifiers a key down had, so this sample tells a chord or a
        /// Command+Tab from typing with Shift.
        public let switchModifierSeen: Bool

        public init(idle: InputIdle, checkedAt: Double, frontFrom: Double, switchModifierSeen: Bool = false) {
            self.idle = idle
            self.checkedAt = checkedAt
            self.frontFrom = frontFrom
            self.switchModifierSeen = switchModifierSeen
        }

        var text: String {
            func s(_ value: Double) -> String { String(format: "%.3fs", value) }
            return "key_down_idle=\(s(idle.keyDown)) flags_changed_idle=\(s(idle.flagsChanged))"
                + " mouse_down_idle=\(s(idle.mouseDown)) mouse_up_idle=\(s(idle.mouseUp))"
                + " switch_modifier_seen=\(switchModifierSeen)"
                + " checked_after_action=\(s(checkedAt)) front_from_after_action=\(s(frontFrom))"
        }
    }

    /// Which key downs after the action started count as the user switching
    /// to the target.
    public enum KeyDownRule: Equatable, Sendable {
        /// Only a key down while Command, Control, or Option is held:
        /// Command+Space and other launchers, app shortcuts, Command+Tab.
        case withSwitchModifier
        /// Every key down, typing included.
        case any
    }

    /// The key down rule in use.
    ///
    /// With `.withSwitchModifier`, a user who types in the app that was in
    /// front (a prompt in Paseo) while the target takes focus gets that app
    /// back, so the next keys go where the user was typing and not into the
    /// target. The cost: a plain key that switches apps (Return in a dialog
    /// of another app, a launcher hotkey with no Command, Control, or
    /// Option) does not count, so a switch to the target made that way
    /// within the watch is undone, and so is a chord that starts and ends
    /// between the action start and the first poll, which no sample sees.
    ///
    /// With `.any`, no key the user presses is ever undone, but the target
    /// that takes focus while the user types elsewhere stays in front and
    /// gets the rest of the user's keys.
    public static let keyDownRule: KeyDownRule = .withSwitchModifier

    /// How long the watch lasts after the action.
    public static let windowSeconds: Double = 2.0
    /// How often the frontmost app is read. The window server reports a new
    /// front process at once, so a short poll ends the target's time in front
    /// sooner; the watch also reads on each app activation notice.
    public static let pollSeconds: Double = 0.02
    /// How often the holder of the keyboard is read while nothing was asked
    /// back. It is an accessibility request, made on its own queue and waited
    /// for at most `KeyFocus.holderWaitSeconds` by the main thread, so it runs
    /// less often than the front read; the second look and the wait for keys
    /// that were asked back read it on each poll.
    public static let keyCheckSeconds: Double = 0.1
    /// How long to wait for the previous app to be in front after asking it to activate.
    public static let confirmSeconds: Double = 0.3
    /// A window request the window server accepted but that has not brought
    /// the user's app back after this long is followed by the public
    /// activation.
    public static let windowRequestGraceSeconds: Double = 0.1
    /// For a process launched after the action started, input this long
    /// before the action still counts as the user's: an app the user just
    /// opened from the Dock can finish launching after the action began. The
    /// target was already running and was not in front when the action
    /// started, so only input after the start can have brought it forward.
    static let inputLookbackSeconds: Double = 1.0
    /// A mouse down or up this long before the target came to the front can
    /// be the click that brought it there (its Dock icon, which switches on
    /// the mouse up, or one of its windows). A running app activates within
    /// this time of the click.
    static let mouseLeadSeconds: Double = 0.3

    private let previous: FrontmostGuard.App
    private let targetPid: pid_t?
    private let actionStart: Double
    private let now: () -> Double
    /// Sees a change of the app in front first. See `FrontmostGuard.FrontReader`.
    private let read: () -> FrontmostGuard.App?
    /// AppKit's frontmost app. Every outcome about the front needs it to
    /// agree with `read`.
    private let confirmFront: () -> FrontmostGuard.App?
    /// Seconds since the last hardware event of one type. See `hardwareIdleSeconds`.
    private let idleSeconds: (CGEventType) -> Double
    /// Whether Command, Control, or Option is held now. See `hardwareSwitchModifierHeld`.
    private let switchModifierHeld: () -> Bool
    private let keyDownRule: KeyDownRule
    private let launchedByAction: (pid_t) -> Bool
    /// The action sent keys, and posted the key window records to the target
    /// itself. See `checkKeys`.
    private let keyboardAction: Bool
    /// The keyboard is watched only when it was with the user's app at the
    /// action start and the user's window is known.
    private let watchesKeys: Bool
    /// The app the keyboard goes to now. See `KeyFocus.holderPid`.
    private let readKeyHolder: () -> FrontmostGuard.App?
    private let correction: FocusCorrection
    private let window: Double
    private let confirm: Double
    private let keyCheck: Double
    private let windowRequestGrace: Double
    private let onFinish: (Result?) -> Void

    private enum Kind {
        case front
        case keyFocus
    }

    /// A correction that was asked for, until it shows or times out.
    private struct Pending {
        let kind: Kind
        let current: FrontmostGuard.App
        let requestedAt: Double
        let afterMs: Int
        let evidence: Evidence
        var steps: FocusCorrection.Steps
        /// The public activation followed a window request that did not show,
        /// or the window request followed key window records that did not.
        var followedUp = false
    }

    private let watchStart: Double
    /// An app that took the front and passed the checks; it is corrected on
    /// the next poll if nothing changed, so a second look comes before the request.
    private var candidate: FrontmostGuard.App?
    /// The same for an app that took the keyboard.
    private var keyCandidate: FrontmostGuard.App?
    /// The last poll that saw no other app in front (or the action start),
    /// so the earliest time a newly seen app can have come forward.
    private var lastSawPrevious: Double
    /// The last read that saw the keyboard with the user's app (or the action
    /// start), so the earliest time another app can have taken it.
    private var lastSawUserKeys: Double
    private var lastKeyCheck = -Double.infinity
    /// Command, Control, or Option was held at the action start or at a poll.
    private var switchModifierSeen: Bool
    private var pending: Pending?
    private var cancelled = false
    private var timer: DispatchSourceTimer?
    /// Run once when the watch ends; the live watch removes its observer here.
    private var stopHooks: [() -> Void] = []

    /// Read from the command thread while the main thread ticks.
    private let stateLock = NSLock()
    private var finished = false
    private var restoring = false

    public var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }

    /// True from the moment a correction starts until the watch ends.
    public var isRestoring: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return restoring && !finished
    }

    public init(
        previous: FrontmostGuard.App,
        targetPid: pid_t? = nil,
        actionStart: Double,
        now: @escaping () -> Double,
        read: @escaping () -> FrontmostGuard.App?,
        confirmFront: (() -> FrontmostGuard.App?)? = nil,
        idleSeconds: @escaping (CGEventType) -> Double,
        switchModifierAtStart: Bool = false,
        switchModifierHeld: @escaping () -> Bool = { false },
        keyDownRule: KeyDownRule = FocusWatch.keyDownRule,
        launchedByAction: @escaping (pid_t) -> Bool = { _ in false },
        keyboardAction: Bool = false,
        keyFocusAtStart: KeyFocus.AtStart = .unknown,
        readKeyHolder: @escaping () -> FrontmostGuard.App? = { nil },
        correction: FocusCorrection,
        window: Double = FocusWatch.windowSeconds,
        confirm: Double = FocusWatch.confirmSeconds,
        keyCheck: Double = FocusWatch.keyCheckSeconds,
        windowRequestGrace: Double = FocusWatch.windowRequestGraceSeconds,
        onFinish: @escaping (Result?) -> Void
    ) {
        self.previous = previous
        self.targetPid = targetPid
        self.actionStart = actionStart
        self.now = now
        self.read = read
        self.confirmFront = confirmFront ?? read
        self.idleSeconds = idleSeconds
        self.switchModifierHeld = switchModifierHeld
        self.switchModifierSeen = switchModifierAtStart
        self.keyDownRule = keyDownRule
        self.launchedByAction = launchedByAction
        self.keyboardAction = keyboardAction
        self.watchesKeys = keyFocusAtStart.userHoldsKeys && keyFocusAtStart.windowId != nil
        self.readKeyHolder = readKeyHolder
        self.correction = correction
        self.window = window
        self.confirm = confirm
        self.keyCheck = keyCheck
        self.windowRequestGrace = windowRequestGrace
        self.onFinish = onFinish
        self.watchStart = now()
        self.lastSawPrevious = actionStart
        self.lastSawUserKeys = actionStart
    }

    /// Ends the watch at the next `tick` (or now, on the main thread). A
    /// correction that was already requested cannot be taken back.
    public func cancel() {
        cancelled = true
    }

    /// One poll. Returns true when the watch is over.
    @discardableResult
    public func tick() -> Bool {
        guard !isFinished else { return true }
        let t = now()
        let current = read()
        // Sampled on every poll: a chord or a Command+Tab holds the modifier
        // for longer than one poll.
        if switchModifierHeld() { switchModifierSeen = true }

        if let pending {
            return confirmPending(pending, current: current, now: t)
        }

        if cancelled || t - watchStart >= window {
            return finish(nil)
        }

        if let waiting = candidate {
            // Second look, right before the request: the app must still be
            // the one that took focus and the user must still be idle.
            guard let current, current.pid == waiting.pid else {
                candidate = nil
                if current == nil || current?.pid == previous.pid { lastSawPrevious = t }
                return false
            }
            // AppKit follows the window server a moment later, so the
            // candidate is kept until it agrees. When it never does, the watch
            // ends with nothing done.
            guard appKitAgrees(current) else { return false }
            let evidence = check(now: t, from: lastSawPrevious)
            if userActed(for: current, evidence: evidence) {
                return finish(Result(previous: previous, current: current, outcome: .userSwitched, evidence: evidence))
            }
            setRestoring()
            let steps = correction.bringBack(user: previous, targetPid: targetPid)
            guard steps.path != .none else {
                return finish(Result(previous: previous, current: current, outcome: .couldNotRestore, evidence: evidence, steps: steps))
            }
            // The waits for the request count from the end of the steps,
            // which can take up to the screen hold cap.
            pending = Pending(kind: .front, current: current, requestedAt: now(), afterMs: elapsedMs(t), evidence: evidence, steps: steps)
            return false
        }

        guard let current, current.pid != previous.pid else {
            lastSawPrevious = t
            return checkKeys(now: t)
        }
        // The front changed, so a move of the keyboard seen before is moot.
        keyCandidate = nil
        // An outcome that ends the watch prints a line and becomes the app
        // in front for the next action, so it needs AppKit to agree too.
        guard current.pid == targetPid || launchedByAction(current.pid) else {
            guard appKitAgrees(current) else { return false }
            return finish(Result(previous: previous, current: current, outcome: .anotherAppTookFocus))
        }
        let evidence = check(now: t, from: lastSawPrevious)
        if userActed(for: current, evidence: evidence) {
            guard appKitAgrees(current) else { return false }
            return finish(Result(previous: previous, current: current, outcome: .userSwitched, evidence: evidence))
        }
        candidate = current
        return false
    }

    /// Whether AppKit's frontmost app is `app`. The window server's front
    /// process may only start a look; see `FrontmostGuard.FrontReader`.
    private func appKitAgrees(_ app: FrontmostGuard.App) -> Bool {
        confirmFront()?.pid == app.pid
    }

    /// Waits for a correction that was asked for to show.
    private func confirmPending(_ waiting: Pending, current: FrontmostGuard.App?, now t: Double) -> Bool {
        var waiting = waiting
        func done(_ outcome: Outcome) -> Bool {
            finish(Result(previous: previous, current: waiting.current, outcome: outcome, evidence: waiting.evidence, steps: waiting.steps))
        }
        switch waiting.kind {
        case .front:
            // AppKit decides whether the user's app is back.
            let back = confirmFront()?.pid == previous.pid
            if back {
                // A stopped watch sends nothing more, not even the raise.
                if !cancelled {
                    correction.raiseUserWindow(user: previous, steps: &waiting.steps)
                }
                return done(.restored(afterMs: waiting.afterMs))
            }
            if cancelled {
                return done(.stoppedAfterRequest)
            }
            if t - waiting.requestedAt >= confirm {
                return done(.couldNotRestore)
            }
            // The activation follows only when an app is known to be in front
            // and it is not the user's: one already in front is never asked
            // again, and no regular app in front (a launcher is open) means the
            // user is busy elsewhere, so nothing is activated.
            if waiting.steps.path == .frontProcess, !waiting.followedUp,
               let current, current.pid != previous.pid,
               t - waiting.requestedAt >= windowRequestGrace {
                waiting.followedUp = true
                correction.activateAfterWindowRequest(user: previous, steps: &waiting.steps)
                pending = waiting
            }
            return false
        case .keyFocus:
            // The keys can come back only while the user's app is in front.
            let appKitFront = confirmFront()
            let holder = readKeyHolder()
            if appKitFront?.pid == previous.pid, holder?.pid == previous.pid {
                return done(.keyFocusReturned(afterMs: waiting.afterMs))
            }
            if cancelled {
                return done(.stoppedAfterKeyFocusRequest)
            }
            if t - waiting.requestedAt >= confirm {
                return done(.couldNotReturnKeyFocus)
            }
            // The window request follows the key window records once, after a
            // short re-check, and only when the keys stayed with the app that
            // took them, that app also took the front from the user's app, and
            // no user input explains it. A request to the user's app while it
            // is in front could close a menu or popover the user has open, and
            // one while a third app is in front would take the user away from it.
            if !waiting.followedUp, t - waiting.requestedAt >= windowRequestGrace,
               holder?.pid == waiting.current.pid, appKitFront?.pid == waiting.current.pid,
               !userActed(for: waiting.current, evidence: check(now: t, from: lastSawUserKeys)) {
                waiting.followedUp = true
                correction.escalateKeyFocus(user: previous, steps: &waiting.steps)
                pending = waiting
            }
            return false
        }
    }

    /// Reads who holds the keyboard while the user's app is in front, and
    /// gives the keys back when a window of the target took them. Returns
    /// true when the watch is over.
    private func checkKeys(now t: Double) -> Bool {
        guard watchesKeys else { return false }
        // A first look is followed by a second one on the next poll; other
        // reads wait for the key check interval.
        if keyCandidate == nil, t - lastKeyCheck < keyCheck { return false }
        lastKeyCheck = t
        // With no regular app in front (a launcher such as Alfred, a system
        // panel) the user's app is unknown, so nothing is given back.
        guard let appKitFront = confirmFront() else {
            keyCandidate = nil
            return false
        }
        guard let holder = readKeyHolder() else { return false }
        if holder.pid == previous.pid {
            keyCandidate = nil
            lastSawUserKeys = t
            return false
        }
        // A process that is neither the target nor launched by the action
        // (a system panel, another app of the user's) is left alone.
        guard holder.pid == targetPid || launchedByAction(holder.pid) else {
            keyCandidate = nil
            return false
        }
        // A keyboard action posts the key window records to the target
        // itself, so the system-wide focused app can follow them while the
        // user's app stays in front and the user's keys still go there. The
        // keys are given back only when the holder is the target and AppKit
        // also says the user's app lost the front.
        if keyboardAction, holder.pid != targetPid || appKitFront.pid == previous.pid {
            keyCandidate = nil
            return false
        }
        let evidence = check(now: t, from: lastSawUserKeys)
        if userActed(for: holder, evidence: evidence) {
            return finish(Result(previous: previous, current: holder, outcome: .userMovedKeyFocus, evidence: evidence))
        }
        guard let waiting = keyCandidate, waiting.pid == holder.pid else {
            // First look; the keys are asked back on the next poll.
            keyCandidate = holder
            return false
        }
        setRestoring()
        let steps = correction.returnKeyFocus(user: previous)
        guard steps.path != .none else {
            return finish(Result(previous: previous, current: holder, outcome: .couldNotReturnKeyFocus, evidence: evidence, steps: steps))
        }
        pending = Pending(kind: .keyFocus, current: holder, requestedAt: now(), afterMs: elapsedMs(t), evidence: evidence, steps: steps)
        return false
    }

    private func elapsedMs(_ t: Double) -> Int {
        max(0, Int(((t - watchStart) * 1000).rounded()))
    }

    private func check(now t: Double, from earliest: Double) -> Evidence {
        Evidence(
            idle: InputIdle.read(idleSeconds),
            checkedAt: t - actionStart,
            frontFrom: earliest - actionStart,
            switchModifierSeen: switchModifierSeen
        )
    }

    private func userActed(for app: FrontmostGuard.App, evidence: Evidence) -> Bool {
        Self.userActed(evidence, isTarget: app.pid == targetPid, keyDownRule: keyDownRule)
    }

    /// Whether hardware input that can switch apps explains the change.
    ///
    /// Only a key down, a modifier change, and a mouse button down or up can
    /// switch apps. Pointer moves, drags, and the scroll wheel never count:
    /// a person who reads or scrolls on the Mac while the agent works moves
    /// the pointer all the time, and with that counted every late
    /// activation of the target was left in front. The cost: a trackpad
    /// gesture that switches spaces or apps is not seen, and the watch can
    /// undo a switch to the target made that way in its short window, as for
    /// input that software posts for the user (see `hardwareIdleSeconds`).
    ///
    /// For the target, which was running and not in front when the action
    /// started:
    /// - a key down after the action started counts as `keyDownRule` says;
    /// - a modifier change after the action started counts when Command,
    ///   Control, or Option was seen held: the release of Command that ends
    ///   a Command+Tab begun before the action. Shift alone (typing a
    ///   capital) does not count;
    /// - a mouse down or up counts from `mouseLeadSeconds` before the
    ///   earliest time the target can have come to the front until now. The
    ///   latest of the two is used, because the Dock switches on the mouse
    ///   up and a slow app can come forward well after the down. The lead
    ///   catches the click that brought it there; a click after that landed
    ///   in the target, which the user is then working in. An earlier click
    ///   was aimed at something else and cannot explain the activation, so
    ///   the watch still restores. Poll times bound the moment of the switch,
    ///   so the earliest bound is used: a click that may be in the window
    ///   counts.
    ///
    /// For a process the action launched, a key down or a mouse down or up
    /// from `inputLookbackSeconds` before the action started counts: the user
    /// may have opened it from the Dock or a launcher just before.
    static func userActed(_ evidence: Evidence, isTarget: Bool, keyDownRule: KeyDownRule = keyDownRule) -> Bool {
        let keyDownAt = evidence.checkedAt - evidence.idle.keyDown
        let mouseAt = evidence.checkedAt - evidence.idle.mouse
        guard isTarget else {
            return max(keyDownAt, mouseAt) > -inputLookbackSeconds
        }
        let keyDownCounts: Bool
        switch keyDownRule {
        case .withSwitchModifier: keyDownCounts = keyDownAt > 0 && evidence.switchModifierSeen
        case .any: keyDownCounts = keyDownAt > 0
        }
        let flagsChangedAt = evidence.checkedAt - evidence.idle.flagsChanged
        let modifierCounts = flagsChangedAt > 0 && evidence.switchModifierSeen
        return keyDownCounts || modifierCounts || mouseAt > evidence.frontFrom - mouseLeadSeconds
    }

    private func setRestoring() {
        stateLock.lock()
        restoring = true
        stateLock.unlock()
    }

    private func finish(_ result: Result?) -> Bool {
        stateLock.lock()
        finished = true
        stateLock.unlock()
        timer?.cancel()
        timer = nil
        let hooks = stopHooks
        stopHooks = []
        for hook in hooks { hook() }
        onFinish(result)
        return true
    }

    // MARK: live

    /// Reads the idle clock of one event source state for one event type.
    typealias IdleClock = (CGEventSourceStateID, CGEventType) -> Double

    /// Seconds since the last hardware input event of one type.
    ///
    /// Only `.hidSystemState` is read. The `.combinedSessionState` clock can
    /// also count the events the plugin posts itself, so right after a key
    /// press of the plugin it looks as if the user acted: a target that the
    /// key brought to the front (Command+n) is then taken for the user's
    /// switch and left in front. The HID clock counts only events from input
    /// devices, so no event the plugin posts can reset it. The cost: input
    /// that software posts for the user (Voice Control clicks, a remote screen
    /// session) is not seen, and the watch can undo a switch to the target
    /// made that way in its short window. That is accepted: a target left in
    /// front by the plugin is the worse failure, and a switch to an app that
    /// was already running and is not the target is never undone.
    static func hardwareIdleSeconds(
        _ type: CGEventType,
        clock: IdleClock = CGEventSource.secondsSinceLastEventType
    ) -> Double {
        clock(.hidSystemState, type)
    }

    /// Whether the flags hold Command, Control, or Option.
    static func hasSwitchModifier(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    }

    /// Whether Command, Control, or Option is held on an input device now.
    /// Only `.hidSystemState` is read, as for the idle clocks: the plugin
    /// posts its keys from a private source to one process, so its own
    /// chords cannot show here.
    public static func hardwareSwitchModifierHeld(
        flags: (CGEventSourceStateID) -> CGEventFlags = CGEventSource.flagsState
    ) -> Bool {
        hasSwitchModifier(flags(.hidSystemState))
    }

    /// Asks one running app to activate. False when it is gone or refuses.
    static func activateApp(_ app: FrontmostGuard.App) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else {
            return false
        }
        return running.activate()
    }

    /// Whether the process started after `date`.
    static func launched(pid: pid_t, after date: Date) -> Bool {
        guard let launch = NSRunningApplication(processIdentifier: pid)?.launchDate else { return false }
        return launch > date
    }

    /// Starts a watch that polls on the main thread.
    public static func live(
        request: FrontmostGuard.WatchRequest,
        onFinish: @escaping (Result?) -> Void
    ) -> FocusWatch {
        let watch = FocusWatch(
            previous: request.previous,
            targetPid: request.targetPid,
            actionStart: request.actionStart,
            now: { ProcessInfo.processInfo.systemUptime },
            read: FrontmostGuard.windowServerFront,
            confirmFront: FrontmostGuard.frontmost,
            idleSeconds: { hardwareIdleSeconds($0) },
            switchModifierAtStart: request.switchModifierAtStart,
            switchModifierHeld: { hardwareSwitchModifierHeld() },
            launchedByAction: { launched(pid: $0, after: request.actionDate) },
            keyboardAction: request.isKeyboardAction,
            keyFocusAtStart: request.keyFocus,
            readKeyHolder: { KeyFocus.boundedHolderPid().flatMap(FrontmostGuard.app(pid:)) },
            correction: FocusCorrection.live(),
            onFinish: onFinish
        )
        DispatchQueue.main.async {
            // A cancel queued before this block already ran on the main
            // thread; the first tick then ends the watch.
            guard !watch.isFinished else { return }
            // An activation notice reads at once, between two polls.
            let center = NSWorkspace.shared.notificationCenter
            let observer = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak watch] _ in watch?.tick() }
            watch.stopHooks.append { center.removeObserver(observer) }
            let source = DispatchSource.makeTimerSource(queue: .main)
            source.schedule(deadline: .now(), repeating: pollSeconds)
            source.setEventHandler { [weak watch] in watch?.tick() }
            watch.timer = source
            source.resume()
        }
        return watch
    }
}
