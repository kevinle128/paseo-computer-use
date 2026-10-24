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

    private let skyLightHandle: UnsafeMutableRawPointer?
    private let setWindowLocationFn: SetWindowLocationFn?
    private let getPSNFn: GetPSNFn?
    private let postRecordFn: PostRecordFn?

    public init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        self.skyLightHandle = handle

        func resolveSymbol(_ name: String) -> UnsafeMutableRawPointer? {
            if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                return p
            }
            if let h = handle, let p = dlsym(h, name) {
                return p
            }
            return nil
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
        guard windowId > 0, let getPSNFn, let postRecordFn else { return }
        var psn = ProcessSerialNumber()
        guard getPSNFn(pid, &psn) == 0 else { return }
        var buf = [UInt8](repeating: 0, count: 0xF8)
        buf[0x04] = 0xF8
        buf[0x08] = 0x0D
        let w = UInt32(truncatingIfNeeded: windowId)
        for i in 0..<4 {
            buf[0x3C + i] = UInt8((w >> (8 * UInt32(i))) & 0xFF)
        }
        buf[0x8A] = 0x01
        _ = buf.withUnsafeBufferPointer { b in
            withUnsafePointer(to: &psn) { psnPtr in
                postRecordFn(psnPtr, b.baseAddress!)
            }
        }
    }

    private func applyWindowTargeting(
        event: CGEvent,
        windowId: Int,
        localPoint: CGPoint
    ) {
        event.setIntegerValueField(.eventSourceUserData, value: kPaseoSyntheticEventUserData)
        if windowId > 0 {
            let wid64 = Int64(windowId)
            if let f51 = CGEventField(rawValue: 51) {
                event.setIntegerValueField(f51, value: wid64)
            }
            if let f91 = CGEventField(rawValue: 91) {
                event.setIntegerValueField(f91, value: wid64)
            }
            if let f92 = CGEventField(rawValue: 92) {
                event.setIntegerValueField(f92, value: wid64)
            }
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

        let target = try nativeId.map { try AXEngine.shared.resolveLiveElement(pid: pid, nativeId: $0, expected: params["expected"]) }

        // A plain left click on a named element uses AXPress first: its
        // success is the only click outcome the helper can actually confirm.
        if let target,
           (buttonStr == "left" || buttonStr == "l"),
           clickCount == 1,
           holdKeys.isEmpty {
            if let frame = target.frame {
                // The halo outlines the window that holds the element.
                let window = (try? AXEngine.shared.currentWindow(pid: pid))?.bounds
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

        let (windowId, windowBounds) = try AXEngine.shared.currentWindow(pid: pid)

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
        let (windowId, windowBounds) = try AXEngine.shared.currentWindow(pid: pid)

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

        let target = try nativeId.map { try AXEngine.shared.resolveLiveElement(pid: pid, nativeId: $0, expected: params["expected"]) }
        let (windowId, windowBounds) = try AXEngine.shared.currentWindow(pid: pid)

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
        focusWithoutRaise(pid: pid, windowId: AXEngine.shared.focusWindowId(pid: pid))

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

        let target = try nativeId.map { try AXEngine.shared.resolveLiveElement(pid: pid, nativeId: $0, expected: params["expected"]) }
        if let target {
            AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        focusWithoutRaise(pid: pid, windowId: AXEngine.shared.focusWindowId(pid: pid))
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
        focusWithoutRaise(pid: pid, windowId: AXEngine.shared.focusWindowId(pid: pid))
        let field = AXEngine.focusedElement(pid: pid)
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

    public func performSecondaryAction(params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String, !action.isEmpty else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'action' parameter.")
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
        guard let nativeId = params["nativeId"] as? String, !nativeId.isEmpty else {
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "Missing 'nativeId'; call get_app_state first."
            )
        }
        return try AXEngine.shared.resolveLiveElement(pid: pid, nativeId: nativeId, expected: params["expected"]).element
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
