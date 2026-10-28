import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

public struct InputSourceStatus: Sendable, Equatable {
    public let inputSourceId: String
    public let isInputMethod: Bool
    /// True for a plain keyboard layout (TIS type keyboard layout), which
    /// sends keystrokes unchanged.
    public let isKeyboardLayout: Bool

    public init(inputSourceId: String, isInputMethod: Bool, isKeyboardLayout: Bool) {
        self.inputSourceId = inputSourceId
        self.isInputMethod = isInputMethod
        self.isKeyboardLayout = isKeyboardLayout
    }
}

public final class InputDriver {
    public static let shared = InputDriver()

    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private typealias PostRecordFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32

    private let setWindowLocationFn: SetWindowLocationFn?
    private let getPSNFn: GetPSNFn?
    private let postRecordFn: PostRecordFn?

    /// The window the last synthetic activation went to, and whether the key
    /// window records went with it. A focus correction posts the same records
    /// again, so the target keeps acting as the active app after the user's
    /// app is brought back.
    struct SyntheticActivation: Equatable {
        let pid: pid_t
        let windowId: Int
        var madeKey: Bool
    }

    private let activationLock = NSLock()
    private var lastActivation: SyntheticActivation?

    public init() {
        func resolveSymbol(_ name: String) -> UnsafeMutableRawPointer? {
            PrivateSymbol.address(name)
        }

        if let sym = resolveSymbol("CGEventSetWindowLocation") ?? resolveSymbol("SLEventSetWindowLocation") {
            self.setWindowLocationFn = unsafeBitCast(sym, to: SetWindowLocationFn.self)
        } else {
            self.setWindowLocationFn = nil
        }

        if let sym = resolveSymbol("GetProcessForPID") {
            self.getPSNFn = unsafeBitCast(sym, to: GetPSNFn.self)
        } else {
            self.getPSNFn = nil
        }

        if let sym = resolveSymbol("SLPSPostEventRecordTo") {
            self.postRecordFn = unsafeBitCast(sym, to: PostRecordFn.self)
        } else {
            self.postRecordFn = nil
        }
    }

    /// The text input source APIs must run on the main thread on recent
    /// macOS versions, and commands run on a worker thread.
    public func currentInputSource() -> InputSourceStatus {
        runOnMainSync { Self.readCurrentInputSource() }
    }

    private static func readCurrentInputSource() -> InputSourceStatus {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return InputSourceStatus(inputSourceId: "com.apple.keylayout.US", isInputMethod: false, isKeyboardLayout: true)
        }
        var sourceId = "com.apple.keylayout.US"
        if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            sourceId = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        }
        var sourceType: String?
        if let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) {
            sourceType = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
        }
        return classifyInputSource(id: sourceId, type: sourceType)
    }

    /// Decides from the TIS id and type whether keystrokes pass through an
    /// input method. Telex and VNI report the "input mode" type, not an
    /// input-method type, so all three input-method types count; an id that
    /// names an input method counts even when the type is unavailable.
    static func classifyInputSource(id: String, type: String?) -> InputSourceStatus {
        let inputMethodTypes: Set<String> = [
            kTISTypeKeyboardInputMethodModeEnabled as String,
            kTISTypeKeyboardInputMethodWithoutModes as String,
            kTISTypeKeyboardInputMode as String,
        ]
        let isIM = id.lowercased().contains("inputmethod") || type.map(inputMethodTypes.contains) == true
        let isLayout = type == (kTISTypeKeyboardLayout as String)
        return InputSourceStatus(inputSourceId: id, isInputMethod: isIM, isKeyboardLayout: isLayout)
    }

    public func focusWithoutRaise(pid: pid_t, windowId: Int) {
        guard postActivationRecord(pid: pid, windowId: windowId) else { return }
        remember(SyntheticActivation(pid: pid, windowId: windowId, madeKey: false))
    }

    private func remember(_ activation: SyntheticActivation) {
        activationLock.lock()
        defer { activationLock.unlock() }
        if activation.madeKey, var last = lastActivation, last.pid == activation.pid, last.windowId == activation.windowId {
            last.madeKey = true
            lastActivation = last
        } else {
            lastActivation = activation
        }
    }

    /// Posts again, to `pid`, the synthetic activation the last action posted
    /// to it, with its key window records when they were sent. False when
    /// the last activation went to another process, or none was posted.
    public func reassertSyntheticActivation(pid: pid_t) -> Bool {
        activationLock.lock()
        let last = lastActivation
        activationLock.unlock()
        guard let last, last.pid == pid, postActivationRecord(pid: pid, windowId: last.windowId) else { return false }
        if last.madeKey {
            _ = postKeyWindowRecords(pid: pid, windowId: last.windowId)
        }
        return true
    }

    /// Posts the synthetic activation record of `windowId` to `pid`, under
    /// the window server lock (`WindowServer.calls`). The record goes to the
    /// target app's process only: the app then acts as the active app, while
    /// the window server leaves the frontmost app and the window order as
    /// they are. A click or
    /// drag posts it before its mouse events, and a key press, `type_text`,
    /// or `paste_text` before its key window records, so the app handles the
    /// input as it would from the user.
    private func postActivationRecord(pid: pid_t, windowId: Int) -> Bool {
        guard windowId > 0, let getPSNFn, let postRecordFn else { return false }
        var buf = [UInt8](repeating: 0, count: 0xF8)
        buf[0x04] = 0xF8
        buf[0x08] = 0x0D
        let w = UInt32(truncatingIfNeeded: windowId)
        for i in 0..<4 {
            buf[0x3C + i] = UInt8((w >> (8 * UInt32(i))) & 0xFF)
        }
        buf[0x8A] = 0x01
        return WindowServer.calls.run {
            var psn = ProcessSerialNumber()
            guard getPSNFn(pid, &psn) == 0 else { return false }
            _ = buf.withUnsafeBufferPointer { b in
                withUnsafePointer(to: &psn) { psnPtr in
                    postRecordFn(psnPtr, b.baseAddress!)
                }
            }
            return true
        }
    }

    /// The two event records that make a window the key window of its app,
    /// posted in order to the app's process. The record `focusWithoutRaise`
    /// posts only activates the process: the app then has no key window, so a
    /// key equivalent that acts on the key window (Close Window, Save) finds
    /// nothing to act on and does nothing, while one that needs no window (New
    /// Window) works. After these records the app takes `windowId` as its key
    /// window, without raising it. Key presses, `type_text`, and `paste_text`
    /// post them before the first key, and a focus correction posts them to
    /// the user's window to give its keys back.
    static func keyWindowRecords(windowId: Int) -> [[UInt8]] {
        let id = UInt32(truncatingIfNeeded: windowId)
        return [UInt8(1), UInt8(2)].map { step in
            var record = [UInt8](repeating: 0, count: 0xF8)
            record[0x04] = 0xF8
            record[0x08] = step
            record[0x3A] = 0x10
            for offset in 0x20..<0x30 {
                record[offset] = 0xFF
            }
            for i in 0..<4 {
                record[0x3C + i] = UInt8((id >> (8 * UInt32(i))) & 0xFF)
            }
            return record
        }
    }

    /// Makes the app's window the key window without raising it or bringing
    /// the app to the front, for keys that act on the key window.
    private func makeKeyWindow(pid: pid_t, windowId: Int) {
        guard postKeyWindowRecords(pid: pid, windowId: windowId) else { return }
        remember(SyntheticActivation(pid: pid, windowId: windowId, madeKey: true))
    }

    /// Posts the key window records of `windowId` to `pid`. A focus correction
    /// also posts them to the user's window to give its key focus back. False
    /// when the calls are missing or the process has no serial number. Both
    /// records go under one take of the window server lock
    /// (`WindowServer.calls`), so no other window server call of the helper
    /// comes between them.
    func postKeyWindowRecords(pid: pid_t, windowId: Int) -> Bool {
        guard windowId > 0, let getPSNFn, let postRecordFn else { return false }
        let records = Self.keyWindowRecords(windowId: windowId)
        return WindowServer.calls.run {
            var psn = ProcessSerialNumber()
            guard getPSNFn(pid, &psn) == 0 else { return false }
            for record in records {
                _ = record.withUnsafeBufferPointer { buffer in
                    withUnsafePointer(to: &psn) { postRecordFn($0, buffer.baseAddress!) }
                }
            }
            return true
        }
    }

    /// The window the plugin named for this command, or nil to use the helper's
    /// own choice (the window of the agent's last read).
    static func requestedWindowId(_ params: [String: Any]) -> Int? {
        (params["windowId"] as? NSNumber)?.intValue
    }

    /// How long to wait for the app to report the target as its focused
    /// window after the key window records were posted. The records take
    /// effect asynchronously, and an app that has just lost the front (the
    /// restore gave it back to the user's app) may still be handling that
    /// when the first records arrive, so the key window records are posted
    /// again on each later try.
    private static let keyWindowSettleMicros: UInt32 = 20_000
    private static let keyWindowSettleTries = 15
    /// The time limit of the whole key window step. Each accessibility
    /// request can block for `AXEngine.messagingTimeoutSeconds`, and one try
    /// makes several, so a hung app would otherwise hold the command (and the
    /// computer) for many seconds.
    static let keyWindowCheckLimitSeconds: Double = 1.5

    /// Thrown by a time limit checkpoint when the deadline has passed.
    struct TimeLimitReached: Error {}

    /// The checkpoint a bounded accessibility step runs before each request:
    /// it throws when the command was cancelled or the deadline (on the
    /// `now` clock) has passed.
    static func timeLimitCheckpoint(now: @escaping () -> Double, deadline: Double) -> () throws -> Void {
        {
            try CommandCancellation.checkCurrent()
            if now() >= deadline { throw TimeLimitReached() }
        }
    }

    private static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    /// The one prelude of every keyboard action (press_key, type_text, and
    /// paste_text, with the paste type_text uses for an input method): the
    /// app's target window becomes its key window without being raised, and the
    /// app must report that window as focused before a key is sent. Returns
    /// nil when it does, else the last check, which says why not. The caller
    /// then sends nothing, because a key would act on whichever other window
    /// the app has as key. An app that does not report its focused window at
    /// all is trusted when the target is its only window. An app with no window
    /// (`windowId` 0) has nothing to focus.
    private func focusKeyWindow(pid: pid_t, windowId: Int) throws -> AXEngine.KeyWindowCheck? {
        guard windowId > 0 else { return nil }
        return try Self.settleKeyWindow(
            post: { [self] attempt in
                if attempt == 0 { focusWithoutRaise(pid: pid, windowId: windowId) }
                makeKeyWindow(pid: pid, windowId: windowId)
            },
            check: { checkpoint in try AXEngine.shared.keyWindowCheck(pid: pid, target: windowId, checkpoint: checkpoint) },
            sleep: { try CommandCancellation.sleepCurrent(micros: Self.keyWindowSettleMicros) },
            tries: Self.keyWindowSettleTries,
            now: Self.uptime,
            limit: Self.keyWindowCheckLimitSeconds
        )
    }

    /// Posts the key window records and polls the check until keys may be
    /// sent; `post` gets the try number, so the records can be sent again.
    /// Returns nil when keys may be sent, else the last check. `check` gets
    /// the checkpoint to run before each accessibility request: a cancel
    /// throws from it, and once `limit` seconds have passed since the start
    /// the step ends with a `.noAnswer` refusal, even in the middle of a try.
    /// The seam has no accessibility or window server call of its own, so
    /// tests drive it with fakes.
    static func settleKeyWindow(
        post: (_ attempt: Int) -> Void,
        check: (_ checkpoint: () throws -> Void) throws -> AXEngine.KeyWindowCheck,
        sleep: () throws -> Void,
        tries: Int,
        now: @escaping () -> Double,
        limit: Double
    ) throws -> AXEngine.KeyWindowCheck? {
        let checkpoint = timeLimitCheckpoint(now: now, deadline: now() + limit)
        var last = AXEngine.KeyWindowCheck(state: .elsewhere, targetIsOnlyWindow: false)
        for attempt in 0..<max(1, tries) {
            post(attempt)
            do {
                last = try check(checkpoint)
            } catch is TimeLimitReached {
                return AXEngine.KeyWindowCheck(state: .noAnswer, targetIsOnlyWindow: false)
            }
            if last.allowsKeys { return nil }
            if attempt < tries - 1 { try sleep() }
        }
        return last
    }

    /// What `unverified` says when the named element did not take the focus.
    /// The plugin adds the element index; the helper never sees indices.
    public static let couldNotFocusElementReason = "could not focus element"

    private func couldNotFocusElement() -> [String: Any] {
        makeActionResult(verification: ActionVerification.unverified(Self.couldNotFocusElementReason))
    }

    /// How long to wait for the app to report the named element as focused.
    private static let elementFocusSettleMicros: UInt32 = 20_000
    private static let elementFocusSettleTries = 8

    /// True when `focused` is `target` or sits inside it. Focus may land on a
    /// child of the element that was asked (a group that hands it to its text
    /// field), but never on a sibling or an unrelated element.
    static func focusIsWithin<E>(
        focused: E?,
        target: E,
        parent: (E) -> E?,
        same: (E, E) -> Bool,
        maxDepth: Int = 24
    ) -> Bool {
        var node = focused
        for _ in 0..<maxDepth {
            guard let current = node else { return false }
            if same(current, target) { return true }
            node = parent(current)
        }
        return false
    }

    /// Asks the app to focus `element` and waits until the app reports that
    /// element, or one inside it, as its focused element. A refused request
    /// still passes when the element already has the focus.
    private func focusNamedElement(_ element: AXUIElement, pid: pid_t) throws -> Bool {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for attempt in 0..<Self.elementFocusSettleTries {
            let held = Self.focusIsWithin(
                focused: AXEngine.focusedElement(pid: pid),
                target: element,
                parent: { node in
                    var ref: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &ref) == .success,
                          let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
                    return unsafeBitCast(ref, to: AXUIElement.self)
                },
                same: { CFEqual($0, $1) }
            )
            if held { return true }
            if attempt < Self.elementFocusSettleTries - 1 {
                try CommandCancellation.sleepCurrent(micros: Self.elementFocusSettleMicros)
            }
        }
        return false
    }

    /// What the refusal says besides the window: which window the app reports
    /// as focused, or that it reports none, so a live run shows which of the
    /// two the app did, and what the agent can do instead: keys cannot reach
    /// that window while the app keeps another one as key.
    static func couldNotFocusReason(windowId: Int, check: AXEngine.KeyWindowCheck) -> String {
        let base = "could not focus window [\(windowId)]"
        let detail: String
        switch check.state {
        case .elsewhere:
            if let reported = check.focusedWindowId {
                detail = " (the app reports [\(reported)] as focused)"
            } else {
                detail = " (the app reports another window as focused)"
            }
        case .unreported:
            detail = " (the app reports no focused window)"
        case .noAnswer:
            detail = " (the app did not answer in time)"
        case .belongs:
            detail = ""
        }
        return base + detail + ". " + couldNotFocusAlternatives
    }

    static let couldNotFocusAlternatives =
        "No keys were sent. To act in that window, use click, secondary_action, or set_value on its elements, or ask the user."

    /// Command+w with no other modifier: the chord that closes the key window.
    static func isCloseWindowChord(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        keyCode == CGKeyCode(kVK_ANSI_W)
            && flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand
    }

    /// What the app said to an AXPress.
    enum PressResult: Equatable {
        case accepted
        /// The request timed out (`.cannotComplete`): the app may still act
        /// on it, so the button counts as pressed.
        case timedOut
        case refused

        init(_ error: AXError) {
            switch error {
            case .success: self = .accepted
            case .cannotComplete: self = .timedOut
            default: self = .refused
            }
        }
    }

    /// What pressing a close button came to.
    enum CloseButtonOutcome: Equatable {
        /// No close button, a disabled one, or the app refused the press.
        case unavailable
        /// The window or tab is gone.
        case closed
        /// The press was accepted and the window or tab is still there (the
        /// app may ask to save first).
        case stillOpen
        /// The press timed out and the window or tab was not seen gone.
        case unknown
    }

    /// Presses the close button and waits, bounded, until `gone` says the
    /// window or tab went away, so the read after the action sees it gone. A
    /// press that timed out is waited for only when `waitsAfterTimeout`: the
    /// window check asks the window server, while the tab check asks the app,
    /// which is not answering. The seam has no accessibility or window server
    /// call of its own, so tests drive it with fakes.
    static func closeWithButton<Button>(
        button: () -> Button?,
        isEnabled: (Button) -> Bool,
        press: (Button) -> PressResult,
        gone: () -> Bool,
        waitsAfterTimeout: Bool,
        sleep: () throws -> Void,
        tries: Int
    ) throws -> CloseButtonOutcome {
        guard let found = button(), isEnabled(found) else { return .unavailable }
        let pressed = press(found)
        switch pressed {
        case .refused: return .unavailable
        case .timedOut where !waitsAfterTimeout: return .unknown
        case .accepted, .timedOut: break
        }
        for attempt in 0..<max(1, tries) {
            if gone() { return .closed }
            if attempt < tries - 1 { try sleep() }
        }
        return pressed == .accepted ? .stillOpen : .unknown
    }

    /// What `unverified` says when Command+w closed the window with its
    /// close button. The plugin (`CLOSED_WITH_CLOSE_BUTTON_REASON` in
    /// tools.ts) matches this string; keep both the same.
    public static let closedWithCloseButtonReason = "closed with its close button"

    /// The plugin (`CLOSE_BUTTON_LEFT_OPEN_REASON` in tools.ts) matches this
    /// string to report a window that closed after the wait; keep both the
    /// same.
    static func closeButtonLeftWindowOpenReason(windowId: Int) -> String {
        "pressed the close button of window [\(windowId)]; the window is still open"
    }

    static func closedTabReason(windowId: Int) -> String {
        "closed the selected tab of window [\(windowId)] with its close button"
    }

    static func closeButtonLeftTabOpenReason(windowId: Int) -> String {
        "pressed the close button of the selected tab of window [\(windowId)]; the tab is still open"
    }

    /// The press timed out: the app may still close the window or the tab.
    static let closeButtonPressedStateUnknownReason = "close button pressed, window state unknown"

    private static let closeSettleMicros: UInt32 = 20_000
    private static let closeSettleTries = 25
    /// The time limit for finding the close button, which may read the
    /// window's tab bar.
    private static let closeControlLimitSeconds: Double = 1.5

    /// Command+w for a window that cannot be made key (an app that is not in
    /// front keeps another window as key). The close button that closes what
    /// Command+w would close is pressed with AXPress: the window's own, or,
    /// in a window with more than one tab, the selected tab's (see
    /// `CloseControl`). No event is posted and no app is activated. Returns
    /// nil when there is no such enabled button, or the app refused the
    /// press, so the caller refuses as for any other chord.
    private func closeWindowWithButton(pid: pid_t, windowId: Int) throws -> [String: Any]? {
        try CommandCancellation.checkCurrent()
        let checkpoint = Self.timeLimitCheckpoint(now: Self.uptime, deadline: Self.uptime() + Self.closeControlLimitSeconds)
        let target: AXEngine.CommandWButton
        do {
            target = try AXEngine.shared.commandWButton(pid: pid, windowId: windowId, checkpoint: checkpoint)
        } catch is TimeLimitReached {
            return nil
        }
        let press: (AXUIElement) -> PressResult = { PressResult(AXUIElementPerformAction($0, kAXPressAction as CFString)) }
        let isEnabled: (AXUIElement) -> Bool = { AXEngine.copyBoolAttribute($0, kAXEnabledAttribute) == true }
        let sleep = { try CommandCancellation.sleepCurrent(micros: Self.closeSettleMicros) }
        let reason: String
        switch target {
        case .none:
            return nil
        case .window(let button):
            let outcome = try Self.closeWithButton(
                button: { button },
                isEnabled: isEnabled,
                press: press,
                gone: { AXEngine.onScreenBounds(windowId: windowId, ownerPid: pid) == nil },
                waitsAfterTimeout: true,
                sleep: sleep,
                tries: Self.closeSettleTries
            )
            switch outcome {
            case .unavailable: return nil
            case .closed: reason = Self.closedWithCloseButtonReason
            case .stillOpen: reason = Self.closeButtonLeftWindowOpenReason(windowId: windowId)
            case .unknown: reason = Self.closeButtonPressedStateUnknownReason
            }
        case .tab(let button):
            // The button goes away with its tab. Each read asks the app, so
            // the reads stop at the deadline and the tab then counts as open.
            let deadline = Self.uptime() + Self.closeControlLimitSeconds
            let outcome = try Self.closeWithButton(
                button: { button },
                isEnabled: isEnabled,
                press: press,
                gone: { Self.uptime() < deadline && AXEngine.isGone(button) },
                waitsAfterTimeout: false,
                sleep: sleep,
                tries: Self.closeSettleTries
            )
            switch outcome {
            case .unavailable: return nil
            case .closed: reason = Self.closedTabReason(windowId: windowId)
            case .stillOpen: reason = Self.closeButtonLeftTabOpenReason(windowId: windowId)
            case .unknown: reason = Self.closeButtonPressedStateUnknownReason
            }
        }
        return makeActionResult(verification: ActionVerification.unverified(reason))
    }

    private func couldNotFocus(windowId: Int, check: AXEngine.KeyWindowCheck) -> [String: Any] {
        makeActionResult(verification: ActionVerification.unverified(Self.couldNotFocusReason(windowId: windowId, check: check)))
    }

    private func applyWindowTargeting(
        event: CGEvent,
        windowId: Int,
        localPoint: CGPoint
    ) {
        event.setIntegerValueField(.eventSourceUserData, value: kPaseoSyntheticEventUserData)
        if windowId > 0 {
            let wid64 = Int64(windowId)
            // The event's own window number. The SDK does not name this field.
            if let eventWindowNumber = CGEventField(rawValue: 51) {
                event.setIntegerValueField(eventWindowNumber, value: wid64)
            }
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: wid64)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: wid64)
            setWindowLocationFn?(event, localPoint)
        }
    }

    /// The source for every event this driver posts. A private state keeps
    /// the events out of the shared hardware state, so they cannot move the
    /// user's pointer or combine with keys the user is holding.
    static func syntheticEventSource() -> CGEventSource? {
        CGEventSource(stateID: .privateState)
    }

    /// Posted events give no delivery receipt, so these paths say so instead
    /// of claiming the effect happened.
    static let eventsPostedUnchecked = "events posted; effect not checked"

    /// An accepted accessibility action (AXPress and others) only means the
    /// app took the request, not that the expected change happened.
    static let actionAcceptedUnchecked = "action accepted, effect not checked"

    /// How long to let the target app process input before reading it back.
    private static let readBackSettleMicros: UInt32 = 60_000

    private func makeActionResult(verification: [String: Any]) -> [String: Any] {
        [
            "ok": true,
            "verification": verification,
        ]
    }

    /// Keeps the overlay on screen during a keyboard or value action. Only
    /// pointer actions show the overlay, so without this the watchdog fades
    /// the halo in the middle of a long type_text. It does not wait for the
    /// main thread.
    private static func keepOverlayAlive() {
        runOnMainAsync {
            OverlayPresenter.shared.keepAlive()
        }
    }

    /// Characters typed between two overlay keep-alives: about 0.5 s at the
    /// 8 ms keystroke pace, well inside the 5 s watchdog.
    static let typingKeepAliveInterval = 64

    /// Typing stops when the app reports another window as focused. An app
    /// that reports nothing, or does not answer in time, cannot show a
    /// change, so it is not stopped.
    static func typingMustStop(_ check: AXEngine.KeyWindowCheck) -> Bool {
        check.state == .elsewhere
    }

    /// The key window check made during a long `type_text`, under the same
    /// time limit as the key window step.
    private func midTypingKeyWindowCheck(pid: pid_t, windowId: Int) throws -> AXEngine.KeyWindowCheck {
        let checkpoint = Self.timeLimitCheckpoint(now: Self.uptime, deadline: Self.uptime() + Self.keyWindowCheckLimitSeconds)
        do {
            return try AXEngine.shared.keyWindowCheck(pid: pid, target: windowId, checkpoint: checkpoint)
        } catch is TimeLimitReached {
            return AXEngine.KeyWindowCheck(state: .noAnswer, targetIsOnlyWindow: false)
        }
    }

    /// The error when the app's focus moved to another window during a long
    /// `type_text`. The user is most likely using the app, so it is a
    /// `user_active` refusal: the agent waits, reads the app again, and types
    /// the rest, and its turn goes on.
    static func typingStoppedError(appName: String, text: String, typedUTF16Units: Int) -> HelperError {
        let typed = typedCharacterCount(text, utf16Units: typedUTF16Units)
        return HelperError(
            code: HelperError.userActive,
            message: "\(appName) moved its focus to another window while typing. Typed \(typed) of \(text.count) characters; the rest was not sent. The user may be using \(appName): wait a few seconds, call get_app_state again, then type the rest."
        )
    }

    /// How many characters the first `utf16Units` UTF-16 units of `text` make.
    static func typedCharacterCount(_ text: String, utf16Units: Int) -> Int {
        String(decoding: Array(text.utf16.prefix(utf16Units)), as: UTF16.self).count
    }

    public func performClick(params: [String: Any]) throws -> [String: Any] {
        // The name of the agent, shown next to the virtual pointer.
        let overlayLabel = params["overlayLabel"] as? String
        let app = try AXEngine.shared.resolveApplication(params: params)
        let pid = app.processIdentifier
        let nativeId = params["nativeId"] as? String
        let buttonStr = (params["button"] as? String ?? "left").lowercased()
        let clickCount = max(1, (params["clickCount"] as? Int) ?? 1)
        let holdKeys = (params["holdKeys"] as? [String]) ?? []
        let flags = try Self.eventFlags(for: holdKeys)
        let durationSeconds = (params["duration"] as? Double) ?? 0.04

        let requestedWindow = Self.requestedWindowId(params)
        if let requestedWindow {
            _ = try AXEngine.shared.currentWindow(pid: pid, requested: requestedWindow)
        }
        let target = try nativeId.map {
            try AXEngine.shared.resolveLiveElement(pid: pid, nativeId: $0, expected: params["expected"], windowId: requestedWindow)
        }

        // A plain left click on a named element uses AXPress first: its
        // success is the only click outcome the helper can actually confirm.
        if let target,
           (buttonStr == "left" || buttonStr == "l"),
           clickCount == 1,
           holdKeys.isEmpty {
            if let frame = target.frame {
                // The halo outlines the window that holds the element.
                let window = (try? AXEngine.shared.currentWindow(pid: pid, requested: requestedWindow))?.bounds
                runOnMainAsync {
                    OverlayPresenter.shared.pointerMove(to: frame.center, window: window, label: overlayLabel)
                    OverlayPresenter.shared.pulse()
                }
            }
            try CommandCancellation.checkCurrent()
            let axErr = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
            if axErr == .success {
                // The app accepted the press; nothing read back its effect.
                return makeActionResult(verification: ActionVerification.unverified(Self.actionAcceptedUnchecked))
            }
        }

        let (windowId, windowBounds) = try AXEngine.shared.currentWindow(pid: pid, requested: requestedWindow)

        let globalPoint: CGPoint
        if let x = (params["x"] as? NSNumber)?.doubleValue,
           let y = (params["y"] as? NSNumber)?.doubleValue {
            globalPoint = CGPoint(x: windowBounds.origin.x + x, y: windowBounds.origin.y + y)
        } else if let frame = target?.frame {
            // The frame was read from the live element just now, never from
            // the snapshot, so a moved element is clicked where it is now.
            globalPoint = frame.center
        } else {
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "Click requires either (x, y) coordinates or an element with a readable frame."
            )
        }

        let localPoint = CGPoint(
            x: globalPoint.x - windowBounds.origin.x,
            y: globalPoint.y - windowBounds.origin.y
        )

        runOnMainAsync {
            OverlayPresenter.shared.pointerMove(to: globalPoint, window: windowBounds, label: overlayLabel)
            OverlayPresenter.shared.pulse()
        }
        try CommandCancellation.checkCurrent()

        focusWithoutRaise(pid: pid, windowId: windowId)

        let (downType, upType, mouseButton) = Self.mouseEventTypes(for: buttonStr)
        // No mouse-moved event before the press: the window id and the
        // window-local point on each event are enough for the app, and the
        // user's pointer must stay where the user left it.
        let src = Self.syntheticEventSource()

        for state in 1...clickCount {
            try CommandCancellation.checkCurrent()
            if let down = CGEvent(
                mouseEventSource: src,
                mouseType: downType,
                mouseCursorPosition: globalPoint,
                mouseButton: mouseButton
            ) {
                down.flags = flags
                down.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                applyWindowTargeting(event: down, windowId: windowId, localPoint: localPoint)
                down.postToPid(pid)
            }
            // A cancel during the hold still sends mouse-up below, so the
            // target app is never left with a button stuck down.
            let held = Result { try CommandCancellation.sleepCurrent(micros: UInt32(max(10_000, Int(durationSeconds * 1_000_000)))) }
            if let up = CGEvent(
                mouseEventSource: src,
                mouseType: upType,
                mouseCursorPosition: globalPoint,
                mouseButton: mouseButton
            ) {
                up.flags = flags
                up.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                applyWindowTargeting(event: up, windowId: windowId, localPoint: localPoint)
                up.postToPid(pid)
            }
            try held.get()
        }

        return makeActionResult(verification: ActionVerification.unverified(Self.eventsPostedUnchecked))
    }

    public func performDrag(params: [String: Any]) throws -> [String: Any] {
        // The name of the agent, shown next to the virtual pointer.
        let overlayLabel = params["overlayLabel"] as? String
        guard let fromX = (params["fromX"] as? NSNumber)?.doubleValue,
              let fromY = (params["fromY"] as? NSNumber)?.doubleValue,
              let toX = (params["toX"] as? NSNumber)?.doubleValue,
              let toY = (params["toY"] as? NSNumber)?.doubleValue else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing drag coordinates.")
        }

        let app = try AXEngine.shared.resolveApplication(params: params)
        let pid = app.processIdentifier
        let holdKeys = (params["holdKeys"] as? [String]) ?? []
        let flags = try Self.eventFlags(for: holdKeys)
        let (windowId, windowBounds) = try AXEngine.shared.currentWindow(pid: pid, requested: Self.requestedWindowId(params))

        let startGlobal = CGPoint(x: windowBounds.origin.x + fromX, y: windowBounds.origin.y + fromY)
        let endGlobal = CGPoint(x: windowBounds.origin.x + toX, y: windowBounds.origin.y + toY)

        runOnMainAsync {
            OverlayPresenter.shared.pointerMove(to: startGlobal, window: windowBounds, label: overlayLabel)
        }
        try CommandCancellation.checkCurrent()
        focusWithoutRaise(pid: pid, windowId: windowId)

        let src = Self.syntheticEventSource()
        if let down = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseDown,
            mouseCursorPosition: startGlobal,
            mouseButton: .left
        ) {
            down.flags = flags
            applyWindowTargeting(
                event: down,
                windowId: windowId,
                localPoint: CGPoint(x: fromX, y: fromY)
            )
            down.postToPid(pid)
        }

        let steps = 12
        var dragError: Error?
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let gx = startGlobal.x + CGFloat(t) * (endGlobal.x - startGlobal.x)
            let gy = startGlobal.y + CGFloat(t) * (endGlobal.y - startGlobal.y)
            let lx = fromX + t * (toX - fromX)
            let ly = fromY + t * (toY - fromY)
            if let drag = CGEvent(
                mouseEventSource: src,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: CGPoint(x: gx, y: gy),
                mouseButton: .left
            ) {
                drag.flags = flags
                applyWindowTargeting(
                    event: drag,
                    windowId: windowId,
                    localPoint: CGPoint(x: lx, y: ly)
                )
                drag.postToPid(pid)
            }
            do {
                try CommandCancellation.sleepCurrent(micros: 8_000)
            } catch {
                // Stop moving but still release the button below.
                dragError = error
                break
            }
        }

        runOnMainAsync {
            OverlayPresenter.shared.pointerMove(to: endGlobal, window: windowBounds, label: overlayLabel)
        }

        if let up = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseUp,
            mouseCursorPosition: endGlobal,
            mouseButton: .left
        ) {
            up.flags = flags
            applyWindowTargeting(
                event: up,
                windowId: windowId,
                localPoint: CGPoint(x: toX, y: toY)
            )
            up.postToPid(pid)
        }
        if let dragError {
            throw dragError
        }

        return makeActionResult(verification: ActionVerification.unverified(Self.eventsPostedUnchecked))
    }

    public func performScroll(params: [String: Any]) throws -> [String: Any] {
        // The name of the agent, shown next to the virtual pointer.
        let overlayLabel = params["overlayLabel"] as? String
        let app = try AXEngine.shared.resolveApplication(params: params)
        let pid = app.processIdentifier
        let direction = (params["direction"] as? String ?? "down").lowercased()
        let pages = (params["pages"] as? NSNumber)?.doubleValue ?? 1.0
        let nativeId = params["nativeId"] as? String

        let requestedWindow = Self.requestedWindowId(params)
        let (windowId, windowBounds) = try AXEngine.shared.currentWindow(pid: pid, requested: requestedWindow)
        let target = try nativeId.map {
            try AXEngine.shared.resolveLiveElement(pid: pid, nativeId: $0, expected: params["expected"], windowId: requestedWindow)
        }

        let globalPoint: CGPoint
        if let x = (params["x"] as? NSNumber)?.doubleValue,
           let y = (params["y"] as? NSNumber)?.doubleValue {
            globalPoint = CGPoint(x: windowBounds.origin.x + x, y: windowBounds.origin.y + y)
        } else if let frame = target?.frame {
            globalPoint = frame.center
        } else {
            globalPoint = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        }

        let localPoint = CGPoint(
            x: globalPoint.x - windowBounds.origin.x,
            y: globalPoint.y - windowBounds.origin.y
        )

        runOnMainAsync {
            OverlayPresenter.shared.pointerMove(to: globalPoint, window: windowBounds, label: overlayLabel)
        }
        try CommandCancellation.checkCurrent()

        let pixels = Int32(pages * 320.0)
        var wheelY: Int32 = 0
        var wheelX: Int32 = 0
        switch direction {
        case "down", "d": wheelY = -pixels
        case "up", "u": wheelY = pixels
        case "right", "r": wheelX = -pixels
        case "left", "l": wheelX = pixels
        default: wheelY = -pixels
        }

        let src = Self.syntheticEventSource()
        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: src,
            units: .pixel,
            wheelCount: 2,
            wheel1: wheelY,
            wheel2: wheelX,
            wheel3: 0
        ) {
            scrollEvent.location = globalPoint
            applyWindowTargeting(event: scrollEvent, windowId: windowId, localPoint: localPoint)
            scrollEvent.postToPid(pid)
        }

        return makeActionResult(verification: ActionVerification.unverified(Self.eventsPostedUnchecked))
    }

    public func performPressKey(params: [String: Any]) throws -> [String: Any] {
        guard let keySpec = params["key"] as? String, !keySpec.isEmpty else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'key' parameter.")
        }
        let app = try AXEngine.shared.resolveApplication(params: params)
        let pid = app.processIdentifier
        // Parsed before anything reaches the app: an unknown key name must
        // fail, never fall back to another key.
        let (keyCode, flags) = try Self.parseKeyChord(keySpec)
        Self.keepOverlayAlive()
        defer { Self.keepOverlayAlive() }
        let keyWindowId = try AXEngine.shared.focusWindowId(pid: pid, requested: Self.requestedWindowId(params))
        if let refused = try focusKeyWindow(pid: pid, windowId: keyWindowId) {
            if Self.isCloseWindowChord(keyCode: keyCode, flags: flags),
               let closed = try closeWindowWithButton(pid: pid, windowId: keyWindowId) {
                return closed
            }
            return couldNotFocus(windowId: keyWindowId, check: refused)
        }

        let durationSeconds = (params["duration"] as? Double) ?? 0.02
        let src = Self.syntheticEventSource()

        try CommandCancellation.checkCurrent()
        var holdError: Error?
        for keyDown in [true, false] {
            if let ev = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: keyDown) {
                ev.flags = flags
                ev.setIntegerValueField(.eventSourceUserData, value: kPaseoSyntheticEventUserData)
                ev.postToPid(pid)
            }
            if keyDown {
                // A cancel during the hold still sends key-up, so no key is
                // left pressed in the target app.
                do {
                    try CommandCancellation.sleepCurrent(micros: UInt32(max(5_000, Int(durationSeconds * 1_000_000))))
                } catch {
                    holdError = error
                }
            }
        }
        if let holdError {
            throw holdError
        }

        return makeActionResult(verification: ActionVerification.unverified(Self.eventsPostedUnchecked))
    }

    /// Whether `type_text` must paste instead of sending keystrokes. An input
    /// method (Vietnamese Telex or VNI, Japanese, Chinese) rewrites keystrokes,
    /// so typed text would arrive changed. Pasting never changes the user's
    /// input source. Only a plain keyboard layout (ABC, US, and similar) takes
    /// keystrokes as they are.
    public static func typesByPasting(source: InputSourceStatus, allowInputMethod: Bool) -> Bool {
        if allowInputMethod {
            return false
        }
        return source.isInputMethod || !source.isKeyboardLayout
    }

    public func performTypeText(params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'text' parameter.")
        }
        let app = try AXEngine.shared.resolveApplication(params: params)
        let pid = app.processIdentifier
        let nativeId = params["nativeId"] as? String
        let allowInputMethod = (params["allowInputMethod"] as? Bool) ?? false
        Self.keepOverlayAlive()
        defer { Self.keepOverlayAlive() }

        let requestedWindow = Self.requestedWindowId(params)
        let keyWindowId = try AXEngine.shared.focusWindowId(pid: pid, requested: requestedWindow)
        let target = try nativeId.map {
            try AXEngine.shared.resolveLiveElement(pid: pid, nativeId: $0, expected: params["expected"], windowId: requestedWindow)
        }
        if let refused = try focusKeyWindow(pid: pid, windowId: keyWindowId) {
            return couldNotFocus(windowId: keyWindowId, check: refused)
        }
        // After the window check, so a refused command changes nothing in the app.
        // Keys go to the app's focused element, so nothing is sent unless the
        // named element (or one inside it) really has the focus.
        if let target, try !focusNamedElement(target.element, pid: pid) {
            return couldNotFocusElement()
        }
        let field = target?.element ?? AXEngine.focusedElement(pid: pid)
        let before = field.flatMap { AXEngine.copyValueString($0) }

        let source = currentInputSource()
        if Self.typesByPasting(source: source, allowInputMethod: allowInputMethod) {
            do {
                try pasteThroughClipboard(text: text, html: false, pid: pid, field: field, before: before)
            } catch let error as HelperError where error.code == HelperError.abortedByUser
                || error.code == HelperError.userIntervened {
                throw error
            } catch {
                let detail = (error as? HelperError)?.message ?? error.localizedDescription
                throw HelperError(
                    code: HelperError.accessibilityError,
                    message: "The input source '\(source.inputSourceId)' is not a plain keyboard layout, so the text was pasted, and the paste failed (\(detail)). Use set_value on the text element instead."
                )
            }
            var verification = try readBackTextEntry(field: field, before: before, entered: text)
            verification["reason"] = "\(verification["reason"] as? String ?? ""); pasted because input source '\(source.inputSourceId)' is not a plain keyboard layout"
            var result = makeActionResult(verification: verification)
            result["inputSourceId"] = source.inputSourceId
            result["inputPath"] = "paste"
            return result
        }

        let src = Self.syntheticEventSource()
        for (index, scalar) in text.utf16.enumerated() {
            // Checked before each character so a cancel stops typing within
            // one keystroke.
            try CommandCancellation.checkCurrent()
            if index > 0, index % Self.typingKeepAliveInterval == 0 {
                Self.keepOverlayAlive()
                // The user may click another window of the same app while the
                // text goes in; the frontmost app does not change then.
                if keyWindowId > 0, Self.typingMustStop(try midTypingKeyWindowCheck(pid: pid, windowId: keyWindowId)) {
                    throw Self.typingStoppedError(
                        appName: app.localizedName ?? app.bundleIdentifier ?? "the app",
                        text: text,
                        typedUTF16Units: index
                    )
                }
            }
            var ch = scalar
            for keyDown in [true, false] {
                if let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: keyDown) {
                    ev.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
                    ev.setIntegerValueField(.eventSourceUserData, value: kPaseoSyntheticEventUserData)
                    ev.postToPid(pid)
                }
            }
            try CommandCancellation.sleepCurrent(micros: 8_000)
        }

        var result = makeActionResult(verification: try readBackTextEntry(field: field, before: before, entered: text))
        result["inputSourceId"] = source.inputSourceId
        result["inputPath"] = "keys"
        return result
    }

    /// How long to wait for the target app to read the pasteboard after
    /// Cmd+V when its field value can be read back.
    static let pasteConsumeTimeoutMicros: UInt32 = 1_500_000
    static let pasteConsumePollMicros: UInt32 = 20_000
    /// The wait when no field value can be read, so consumption cannot be
    /// observed.
    static let pasteConsumeFallbackMicros: UInt32 = 500_000

    public func performPasteText(params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'text' parameter.")
        }
        let format = (params["format"] as? String) ?? "text"
        Self.keepOverlayAlive()
        defer { Self.keepOverlayAlive() }
        guard format == "text" || format == "html" else {
            // No Markdown converter exists here; pasting the raw text would
            // silently differ from what the agent asked for.
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "paste_text format '\(format)' is not supported. Use format 'text' or 'html'."
            )
        }
        let app = try AXEngine.shared.resolveApplication(params: params)
        let pid = app.processIdentifier
        let requestedWindow = Self.requestedWindowId(params)
        let keyWindowId = try AXEngine.shared.focusWindowId(pid: pid, requested: requestedWindow)
        let target = try (params["nativeId"] as? String).map {
            try AXEngine.shared.resolveLiveElement(pid: pid, nativeId: $0, expected: params["expected"], windowId: requestedWindow)
        }
        if let refused = try focusKeyWindow(pid: pid, windowId: keyWindowId) {
            return couldNotFocus(windowId: keyWindowId, check: refused)
        }
        // After the window check, so a refused command changes nothing in the app.
        // Keys go to the app's focused element, so nothing is sent unless the
        // named element (or one inside it) really has the focus.
        if let target, try !focusNamedElement(target.element, pid: pid) {
            return couldNotFocusElement()
        }
        let field = target?.element ?? AXEngine.focusedElement(pid: pid)
        let before = field.flatMap { AXEngine.copyValueString($0) }

        try pasteThroughClipboard(text: text, html: format == "html", pid: pid, field: field, before: before)
        return makeActionResult(verification: try readBackTextEntry(field: field, before: before, entered: text))
    }

    /// Puts `text` on the general pasteboard, sends Cmd+V, waits until the app
    /// has read it, and puts the user's clipboard back exactly as it was.
    private func pasteThroughClipboard(
        text: String,
        html: Bool,
        pid: pid_t,
        field: AXUIElement?,
        before: String?
    ) throws {
        try CommandCancellation.checkCurrent()
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            saved.restore(to: pb)
            throw HelperError(code: HelperError.accessibilityError, message: "Could not write the text to the clipboard.")
        }
        if html {
            pb.setString(text, forType: .html)
        }
        // Clipboard managers such as Maccy and Raycast skip items with these
        // markers, so the pasted text does not stay in their history after
        // the user's clipboard is restored.
        pb.setData(Data(), forType: Self.transientPasteboardType)
        pb.setData(Data(), forType: Self.concealedPasteboardType)
        let ownChangeCount = pb.changeCount
        // Restore on every exit, including a cancel during the paste. A copy
        // the user made during the paste is newer than the snapshot and is
        // kept.
        defer {
            if pb.changeCount == ownChangeCount {
                saved.restore(to: pb)
            }
        }

        // Synthesize Cmd+V (keyCode 9 = V). A cancel between the two events
        // still sends key-up, so Cmd and V are never left pressed.
        let src = Self.syntheticEventSource()
        var cancelError: Error?
        for keyDown in [true, false] {
            if let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown) {
                ev.flags = .maskCommand
                ev.setIntegerValueField(.eventSourceUserData, value: kPaseoSyntheticEventUserData)
                ev.postToPid(pid)
            }
            if cancelError == nil {
                do {
                    try CommandCancellation.sleepCurrent(micros: 15_000)
                } catch {
                    cancelError = error
                }
            }
        }

        // Once Cmd+V is posted the app may read the pasteboard at any time.
        // This wait is not cancellable: restoring the user's clipboard before
        // the app reads it would paste the user's own clipboard content.
        Self.waitForPasteConsumed(field: field, before: before)
        if let cancelError {
            throw cancelError
        }
        try CommandCancellation.checkCurrent()
    }

    /// Returns when the field's value changes (the app has read the
    /// pasteboard), or after a bounded time. Without a readable field there
    /// is no signal, so a fixed wait is used.
    private static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static func waitForPasteConsumed(field: AXUIElement?, before: String?) {
        guard let field, before != nil else {
            usleep(pasteConsumeFallbackMicros)
            return
        }
        var waited: UInt32 = 0
        while waited < pasteConsumeTimeoutMicros {
            usleep(pasteConsumePollMicros)
            waited += pasteConsumePollMicros
            if AXEngine.copyValueString(field) != before {
                return
            }
        }
    }

    public func performSetValue(params: [String: Any]) throws -> [String: Any] {
        guard let value = params["value"] as? String else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'value' parameter.")
        }
        Self.keepOverlayAlive()
        defer { Self.keepOverlayAlive() }
        let app = try AXEngine.shared.resolveApplication(params: params)
        let pid = app.processIdentifier
        let element = try resolveRequiredElement(pid: pid, params: params)

        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        if err != .success {
            throw HelperError(
                code: HelperError.accessibilityError,
                message: "AXUIElementSetAttributeValue failed with error \(err.rawValue)."
            )
        }

        try CommandCancellation.sleepCurrent(micros: Self.readBackSettleMicros)
        return makeActionResult(verification: ActionVerification.setValue(
            requested: value,
            readBack: AXEngine.copyValueString(element)
        ))
    }

    public func performSelectText(params: [String: Any]) throws -> [String: Any] {
        guard let targetText = params["text"] as? String else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'text' parameter.")
        }
        let app = try AXEngine.shared.resolveApplication(params: params)
        let pid = app.processIdentifier
        let selectionType = (params["selection"] as? String) ?? "text"
        Self.keepOverlayAlive()
        defer { Self.keepOverlayAlive() }

        let element = try resolveRequiredElement(pid: pid, params: params)

        let prefix = (params["prefix"] as? String) ?? ""
        let suffix = (params["suffix"] as? String) ?? ""
        let currentValue = AXEngine.copyValueString(element) ?? ""
        let nsValue = currentValue as NSString
        // The prefix and suffix pick one occurrence when the text appears more
        // than once; only the text itself is selected.
        let contextRange = nsValue.range(of: prefix + targetText + suffix)
        let foundRange = contextRange.location == NSNotFound
            ? contextRange
            : NSRange(location: contextRange.location + (prefix as NSString).length, length: (targetText as NSString).length)
        // Selecting everything on a miss would let the next typed text replace
        // the whole field, so a miss is an error.
        guard foundRange.location != NSNotFound else {
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "The text to select was not found in the element."
            )
        }
        let finalRange: CFRange
        switch selectionType {
        case "cursor_before":
            finalRange = CFRange(location: foundRange.location, length: 0)
        case "cursor_after":
            finalRange = CFRange(location: foundRange.location + foundRange.length, length: 0)
        default:
            finalRange = CFRange(location: foundRange.location, length: foundRange.length)
        }

        var cfRange = finalRange
        guard let axVal = AXValueCreate(.cfRange, &cfRange) else {
            throw HelperError(code: HelperError.accessibilityError, message: "Could not build the selection range.")
        }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axVal)
        if err != .success {
            throw HelperError(
                code: HelperError.accessibilityError,
                message: "Setting the selected text range failed with error \(err.rawValue)."
            )
        }

        return makeActionResult(verification: ActionVerification.selection(
            requested: finalRange,
            readBack: Self.copySelectedRange(element)
        ))
    }

    /// Accessibility actions that put a window in front of the user's work.
    static func raisesWindow(_ action: String) -> Bool {
        action == kAXRaiseAction as String
    }

    public func performSecondaryAction(params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String, !action.isEmpty else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'action' parameter.")
        }
        if Self.raisesWindow(action) {
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "\(action) raises the window and brings the app to the front, which Computer Use never does to the user's screen."
            )
        }
        let app = try AXEngine.shared.resolveApplication(params: params)
        let pid = app.processIdentifier
        let element = try resolveRequiredElement(pid: pid, params: params)

        let err = AXUIElementPerformAction(element, action as CFString)
        if err != .success {
            throw HelperError(
                code: HelperError.accessibilityError,
                message: "AXUIElementPerformAction(\(action)) failed with error \(err.rawValue)."
            )
        }

        // The app accepted the action; nothing read back its effect.
        return makeActionResult(verification: ActionVerification.unverified(Self.actionAcceptedUnchecked))
    }

    private func resolveRequiredElement(pid: pid_t, params: [String: Any]) throws -> AXUIElement {
        let requestedWindow = Self.requestedWindowId(params)
        if let requestedWindow {
            _ = try AXEngine.shared.currentWindow(pid: pid, requested: requestedWindow)
        }
        guard let nativeId = params["nativeId"] as? String, !nativeId.isEmpty else {
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "Missing 'nativeId'; call get_app_state first."
            )
        }
        return try AXEngine.shared.resolveLiveElement(
            pid: pid,
            nativeId: nativeId,
            expected: params["expected"],
            windowId: requestedWindow
        ).element
    }

    private func readBackTextEntry(field: AXUIElement?, before: String?, entered: String) throws -> [String: Any] {
        guard let field else {
            return ActionVerification.unverified("no focused text field to read back")
        }
        try CommandCancellation.sleepCurrent(micros: Self.readBackSettleMicros)
        return ActionVerification.textEntry(
            before: before,
            after: AXEngine.copyValueString(field),
            entered: entered
        )
    }

    private static func copySelectedRange(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let val = ref,
              CFGetTypeID(val) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(val, to: AXValue.self), .cfRange, &range) else {
            return nil
        }
        return range
    }

    private static func mouseEventTypes(for button: String) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case "right", "r":
            return (.rightMouseDown, .rightMouseUp, .right)
        case "middle", "m":
            return (.otherMouseDown, .otherMouseUp, .center)
        default:
            return (.leftMouseDown, .leftMouseUp, .left)
        }
    }

    private static let modifierNames: Set<String> = [
        "cmd", "command", "meta", "super", "shift", "alt", "option", "opt", "ctrl", "control",
    ]

    /// Unknown modifier names are an error: dropping one silently would send
    /// a different chord than the agent asked for.
    static func eventFlags(for keys: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for k in keys {
            switch k.lowercased() {
            case "cmd", "command", "meta", "super":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "alt", "option", "opt":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            default:
                throw HelperError(code: HelperError.malformedRequest, message: "Unknown modifier key '\(k)'.")
            }
        }
        return flags
    }

    /// Parses "Return" or "Command+Shift+s". An unknown key name is an error,
    /// never a default key: pressing Return by mistake can submit a form or
    /// send a message.
    /// "+" is the separator, so the plus key itself is written as a final
    /// "++" ("cmd++") or as "+" alone. A main key of " " is the space bar.
    public static func parseKeyChord(_ chord: String) throws -> (CGKeyCode, CGEventFlags) {
        var body = chord
        var plusKey = false
        if chord == "+" {
            body = ""
            plusKey = true
        } else if chord.hasSuffix("++") {
            body = String(chord.dropLast(2))
            plusKey = true
        }
        let rawParts = body.isEmpty && plusKey
            ? []
            : body.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let parts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        let modifiers: [String]
        let code: CGKeyCode
        var extraFlags: CGEventFlags = []
        if plusKey {
            modifiers = parts
            // The plus key on the ANSI layout is Shift with the equal key,
            // which is what a physical press sends.
            code = CGKeyCode(kVK_ANSI_Equal)
            extraFlags = .maskShift
        } else {
            guard let rawMain = rawParts.last, let trimmed = parts.last else {
                throw HelperError(code: HelperError.malformedRequest, message: "Key chord '\(chord)' has no key.")
            }
            let mainKey = trimmed.isEmpty && !rawMain.isEmpty && rawMain.allSatisfy({ $0 == " " }) ? " " : trimmed
            guard !mainKey.isEmpty else {
                throw HelperError(code: HelperError.malformedRequest, message: "Key chord '\(chord)' has no key.")
            }
            guard let found = keyCode(for: mainKey) else {
                throw HelperError(code: HelperError.malformedRequest, message: "Unknown key '\(mainKey)' in '\(chord)'.")
            }
            modifiers = Array(parts.dropLast())
            code = found
        }
        for modifier in modifiers where !modifierNames.contains(modifier) {
            throw HelperError(code: HelperError.malformedRequest, message: "Unknown modifier key '\(modifier)' in '\(chord)'.")
        }
        return (code, try eventFlags(for: modifiers).union(extraFlags))
    }

    private static let namedKeyCodes: [String: Int] = [
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, " ": kVK_Space,
        "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "escape": kVK_Escape, "esc": kVK_Escape,
        "up": kVK_UpArrow, "arrowup": kVK_UpArrow, "down": kVK_DownArrow, "arrowdown": kVK_DownArrow,
        "left": kVK_LeftArrow, "arrowleft": kVK_LeftArrow, "right": kVK_RightArrow, "arrowright": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "minus": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "equal": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
    ]

    /// Key codes of the ANSI US layout. Returns nil for an unknown name.
    public static func keyCode(for key: String) -> CGKeyCode? {
        namedKeyCodes[key].map { CGKeyCode($0) }
    }
}
