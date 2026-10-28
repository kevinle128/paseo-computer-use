import AppKit
import Foundation

/// The steps that give the user back the front, or the keyboard, after an
/// action made another app take it. `FocusWatch` decides when to correct;
/// this type only runs the steps and reports which ran.
///
/// Bringing the user's app back to the front:
/// 1. Hold screen updates (`ScreenUpdateGate`, at most 250 ms), so the
///    user sees one change. Skipped when the hold is not available.
/// 2. Post the synthetic activation of the action again to the target, so it
///    keeps acting as the active app for the agent's next action.
/// 3. Ask the window server to bring the user's window to the front and
///    post the key window records to it. When that request is not available
///    or refused, or the user's window is not known, ask the user's app to
///    activate.
/// The user's window is read again right before the steps, not taken from
/// the action start: the user's app may have opened a window since, and a
/// request for the older one would put the new one behind it.
/// 4. Release the hold.
/// After the user's app is in front again, `raiseUserWindow` puts the user's
/// window back on top of its app when another of its windows is above it.
///
/// Giving key focus back (the user's app stayed in front but another
/// process's window took the keys) posts the key window records to the
/// user's window only. It sends no front request and no activation to the
/// user's app, which is in front: a request to an app already in front can
/// close the menu, popover, or completion list the user has open there.
/// `escalateKeyFocus` follows with the window request only when the keys
/// stayed with the target and the user's app lost the front to it; `FocusWatch`
/// decides that. It holds no screen updates and never activates the target.
///
/// The target is never hidden or deactivated, and the only app ever
/// activated is the user's.
public struct FocusCorrection {
    /// How the user's app or window was asked to come back.
    public enum Path: String, Equatable, Sendable {
        /// The window server request with the user's window and its key
        /// window records.
        case frontProcess = "front_process"
        /// The public activation of the user's app.
        case activate
        /// The window request was accepted but did not take effect in time,
        /// so the public activation followed.
        case frontProcessThenActivate = "front_process_then_activate"
        /// Only the key window records reached the user's window.
        case keyRecords = "key_records"
        /// The key window records did not bring the keys back and the user's
        /// app lost the front, so the window request followed.
        case keyRecordsThenFrontProcess = "key_records_then_front_process"
        /// As above, with the public activation because the window request
        /// was missing or refused.
        case keyRecordsThenActivate = "key_records_then_activate"
        /// Nothing could be asked.
        case none
    }

    /// Which steps ran, for the audit log.
    public struct Steps: Equatable, Sendable {
        /// Nil when no screen updates were held.
        public var gate: ScreenUpdateGate.Report?
        public var path: Path = .none
        /// The synthetic activation was posted to the target again.
        public var targetReasserted = false
        /// The key window records were posted to the user's window.
        public var keyFocusReturned = false
        /// `AXRaise` put the user's window back on top of its app.
        public var userWindowRaised = false
        /// The user's window the requests named, read right before them.
        public var userWindowId: Int?

        public init(
            gate: ScreenUpdateGate.Report? = nil,
            path: Path = .none,
            targetReasserted: Bool = false,
            keyFocusReturned: Bool = false,
            userWindowRaised: Bool = false
        ) {
            self.gate = gate
            self.path = path
            self.targetReasserted = targetReasserted
            self.keyFocusReturned = keyFocusReturned
            self.userWindowRaised = userWindowRaised
        }

        var text: String {
            let held = gate.map { "\($0.heldMs)" } ?? "none"
            let overCap = gate.map { "\($0.overCap)" } ?? "none"
            let releasedBy = gate?.releasedBy.rawValue ?? "none"
            return "gate_held_ms=\(held) gate_over_cap=\(overCap) gate_released_by=\(releasedBy) restore_path=\(path.rawValue)"
                + " target_reasserted=\(targetReasserted) key_focus_returned=\(keyFocusReturned)"
                + " user_window_raised=\(userWindowRaised)"
        }
    }

    /// Nil when screen updates cannot be held.
    let gate: ScreenUpdateGate?
    /// Posts the action's synthetic activation to the target again. False
    /// when there is none to post.
    let reassertTarget: (pid_t) -> Bool
    /// Asks the window server to bring this window of this process to the
    /// front. False when the request is missing or refused.
    let requestFront: (pid_t, Int) -> Bool
    /// Posts the key window records to this window. False when they could
    /// not be posted.
    let postKeyRecords: (pid_t, Int) -> Bool
    /// Asks the app to activate. False when it is gone or refused.
    let activate: (FrontmostGuard.App) -> Bool
    /// Raises the window when another window of its app is above it. True
    /// when it raised.
    let raiseIfBuried: (pid_t, Int) -> Bool
    /// The user's window now: the app's focused window, else its topmost
    /// normal window. Nil when neither is known.
    let readUserWindowId: (pid_t) -> Int?

    public init(
        gate: ScreenUpdateGate?,
        reassertTarget: @escaping (pid_t) -> Bool,
        requestFront: @escaping (pid_t, Int) -> Bool,
        postKeyRecords: @escaping (pid_t, Int) -> Bool,
        activate: @escaping (FrontmostGuard.App) -> Bool,
        raiseIfBuried: @escaping (pid_t, Int) -> Bool,
        readUserWindowId: @escaping (pid_t) -> Int?
    ) {
        self.gate = gate
        self.reassertTarget = reassertTarget
        self.requestFront = requestFront
        self.postKeyRecords = postKeyRecords
        self.activate = activate
        self.raiseIfBuried = raiseIfBuried
        self.readUserWindowId = readUserWindowId
    }

    /// Brings the user's app, and its window when known, back to the front.
    /// `steps.path` is `.none` when nothing could be asked.
    public func bringBack(user: FrontmostGuard.App, targetPid: pid_t?) -> Steps {
        var steps = Steps()
        // Read before the hold, so the hold does not wait on the user's app.
        let userWindowId = readUserWindowId(user.pid)
        steps.userWindowId = userWindowId
        let body = {
            if let targetPid {
                steps.targetReasserted = reassertTarget(targetPid)
            }
            if let userWindowId, requestFront(user.pid, userWindowId) {
                steps.keyFocusReturned = postKeyRecords(user.pid, userWindowId)
                steps.path = .frontProcess
            } else if activate(user) {
                steps.path = .activate
            }
        }
        if let gate {
            steps.gate = gate.run(body).report
        } else {
            body()
        }
        return steps
    }

    /// The public activation, after a window request that was accepted but
    /// did not bring the user's app back in time.
    public func activateAfterWindowRequest(user: FrontmostGuard.App, steps: inout Steps) {
        if activate(user) {
            steps.path = .frontProcessThenActivate
        }
    }

    /// Puts the window the requests named back on top of its app when it is
    /// not.
    public func raiseUserWindow(user: FrontmostGuard.App, steps: inout Steps) {
        guard let userWindowId = steps.userWindowId else { return }
        steps.userWindowRaised = raiseIfBuried(user.pid, userWindowId)
    }

    /// Gives the keys back to the user's window while the user's app stayed
    /// in front: the key window records only. `steps.path` is `.none` when
    /// the user's window is not known or the records could not be posted.
    public func returnKeyFocus(user: FrontmostGuard.App) -> Steps {
        var steps = Steps()
        guard let userWindowId = readUserWindowId(user.pid) else { return steps }
        steps.userWindowId = userWindowId
        if postKeyRecords(user.pid, userWindowId) {
            steps.keyFocusReturned = true
            steps.path = .keyRecords
        }
        return steps
    }

    /// The key window records did not bring the keys back and the target
    /// took the front from the user's app: ask the window server to bring
    /// the user's window back, else activate the user's app. Only
    /// `FocusWatch` calls it, and only when the user's app is not in front.
    public func escalateKeyFocus(user: FrontmostGuard.App, steps: inout Steps) {
        if let userWindowId = readUserWindowId(user.pid) {
            steps.userWindowId = userWindowId
        }
        if let userWindowId = steps.userWindowId, requestFront(user.pid, userWindowId) {
            steps.keyFocusReturned = postKeyRecords(user.pid, userWindowId) || steps.keyFocusReturned
            steps.path = .keyRecordsThenFrontProcess
        } else if activate(user) {
            steps.path = .keyRecordsThenActivate
        }
    }

    /// The correction of the helper process.
    public static func live() -> FocusCorrection {
        FocusCorrection(
            gate: ScreenUpdateGate.live(),
            reassertTarget: { InputDriver.shared.reassertSyntheticActivation(pid: $0) },
            requestFront: { WindowServer.shared.requestFront(pid: $0, windowId: $1) },
            postKeyRecords: { InputDriver.shared.postKeyWindowRecords(pid: $0, windowId: $1) },
            activate: FocusWatch.activateApp,
            raiseIfBuried: { KeyFocus.raiseIfBuried(pid: $0, windowId: $1) },
            readUserWindowId: { KeyFocus.userWindowId(pid: $0) }
        )
    }
}
