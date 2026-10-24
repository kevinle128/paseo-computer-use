import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct HelperError: Error, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    // Wire codes. The TypeScript side lists the same strings in
    // contract/errors.ts (HELPER_ERROR_CODES); keep both in sync.
    public static let malformedRequest = "malformed_request"
    public static let missingCommand = "missing_command"
    public static let unknownCommand = "unknown_command"
    public static let internalError = "internal_error"
    public static let appBlocked = "app_blocked"
    public static let appNotFound = "app_not_found"
    public static let invalidApp = "invalid_app"
    public static let accessibilityError = "accessibility_error"
    public static let abortedByUser = "aborted_by_user"
    public static let userIntervened = "user_intervened"
    /// The named element is gone or no longer looks like it did in the latest
    /// snapshot. Kept separate from accessibilityError so a real AX failure on
    /// a live element is not reported as stale.
    public static let staleElement = "stale_element"
}

public struct AXBoundsSnapshot: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The same rectangle relative to `origin` (for example a window's
    /// top-left corner).
    public func relative(to origin: CGPoint) -> AXBoundsSnapshot {
        AXBoundsSnapshot(x: x - Double(origin.x), y: y - Double(origin.y), width: width, height: height)
    }

    public var center: CGPoint {
        CGPoint(x: x + width / 2.0, y: y + height / 2.0)
    }

    public func toDictionary() -> [String: Any] {
        [
            "x": x,
            "y": y,
            "width": width,
            "height": height,
        ]
    }
}

public struct AXNodeSnapshot: Sendable {
    public let nativeId: String
    public let role: String
    public let subrole: String?
    public let name: String?
    public let nodeDescription: String?
    public let value: String?
    public let bounds: AXBoundsSnapshot?
    public let states: [String]
    public let actions: [String]
    public let children: [AXNodeSnapshot]

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "native_id": nativeId,
            "role": role,
        ]
        if let subrole, !subrole.isEmpty { dict["subrole"] = subrole }
        if let name, !name.isEmpty { dict["name"] = name }
        if let nodeDescription, !nodeDescription.isEmpty { dict["description"] = nodeDescription }
        if let value { dict["value"] = value }
        if let bounds { dict["bounds"] = bounds.toDictionary() }
        if !states.isEmpty { dict["states"] = states }
        if !actions.isEmpty { dict["actions"] = actions }
        if !children.isEmpty {
            dict["children"] = children.map { $0.toDictionary() }
        }
        return dict
    }
}

public final class AXEngine {
    public static let shared = AXEngine()

    public static let maxTraversalDepth = 28
    public static let maxNodeCount = 1500

    /// One cache per app, shared by every agent: it only maps a native id to
    /// the element handle at that path. Whether that element is still the one
    /// an agent saw is checked against the signature the agent sends.
    private struct AppElementCache {
        var byNativeId: [String: AXUIElement] = [:]
        var windowId: Int = 0
        /// The window origin the snapshot's frames are relative to.
        var windowOrigin: CGPoint = .zero
    }

    private var appCaches: [pid_t: AppElementCache] = [:]

    /// Accessibility reads that timed out during the current walk.
    private var walkTimeouts = 0

    /// A walk that hits this many timed-out reads stops: the app is hung, and
    /// with up to `maxNodeCount` elements the walk would otherwise block for
    /// minutes.
    public static let maxWalkTimeouts = 3

    /// How long one accessibility request to another app may block. The
    /// system default is several seconds, which lets a hung app stall a
    /// command for a very long time.
    public static let messagingTimeoutSeconds: Float = 1.0

    public init() {}

    /// Sets the accessibility messaging timeout for every element this process
    /// creates. Setting it on the system-wide element applies it process-wide.
    public static func configureMessagingTimeout(seconds: Float = messagingTimeoutSeconds) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// Resolves an app the agent named and refuses blocked apps. The raw
    /// string is checked first, so a blocked bundle id is refused even when
    /// the app is not running. The resolved bundle id is checked again,
    /// because a display name or a partial name can resolve to a blocked app.
    /// Both checks run before any accessibility read or screenshot.
    public func resolveApplication(_ identifier: String, blocking blockList: AppBlockList) throws -> NSRunningApplication {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError(code: HelperError.invalidApp, message: "Application identifier must not be empty.")
        }
        try blockList.check(trimmed)

        let runningApps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let lower = trimmed.lowercased()

        // 1. Exact bundle identifier, 2. exact name or bundle file name,
        // 3. substring of the name or bundle identifier.
        let match = runningApps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(trimmed) == .orderedSame })
            ?? runningApps.first(where: {
                $0.localizedName?.lowercased() == lower ||
                $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == lower ||
                $0.bundleURL?.path.lowercased() == lower
            })
            ?? runningApps.first(where: {
                ($0.localizedName?.lowercased().contains(lower) ?? false) ||
                ($0.bundleIdentifier?.lowercased().contains(lower) ?? false)
            })

        guard let match else {
            throw HelperError(
                code: HelperError.appNotFound,
                message: "Running application '\(trimmed)' was not found."
            )
        }
        if let bundleId = match.bundleIdentifier {
            try blockList.check(bundleId)
        }
        return match
    }

    /// Resolves the app named by a command's `app` parameter against the
    /// block list the command carries.
    public func resolveApplication(params: [String: Any]) throws -> NSRunningApplication {
        guard let appName = params["app"] as? String else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'app' parameter.")
        }
        return try resolveApplication(appName, blocking: AppBlockList(params: params))
    }

    public func listApps(blocking blockList: AppBlockList) -> [[String: Any]] {
        let windowsByPid = collectWindowsByPid(blocking: blockList)
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy != .prohibited
        }

        var items: [[String: Any]] = []
        for app in runningApps {
            if let bundleId = app.bundleIdentifier, blockList.blocks(bundleId) {
                continue
            }
            let displayName = app.localizedName
                ?? app.bundleURL?.deletingPathExtension().lastPathComponent
                ?? app.bundleIdentifier
                ?? "PID-\(app.processIdentifier)"
            let id = app.bundleIdentifier ?? displayName
            var entry: [String: Any] = [
                "id": id,
                "displayName": displayName,
                "isRunning": true,
            ]
            if let bundleId = app.bundleIdentifier {
                entry["bundleIdentifier"] = bundleId
            }
            if let appWindows = windowsByPid[app.processIdentifier], !appWindows.isEmpty {
                entry["windows"] = appWindows
            }
            items.append(entry)
        }
        return items
    }

    public func listWindows(appFilter: String? = nil, blocking blockList: AppBlockList) throws -> [[String: Any]] {
        var filterPid: pid_t?
        if let appFilter, !appFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let resolved = try resolveApplication(appFilter, blocking: blockList)
            filterPid = resolved.processIdentifier
        }

        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var results: [[String: Any]] = []
        for info in windowInfoList {
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            if layer != 0 { continue }
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowId = info[kCGWindowNumber as String] as? Int else {
                continue
            }
            if let filterPid, ownerPid != filterPid {
                continue
            }
            let runningApp = NSRunningApplication(processIdentifier: ownerPid)
            let bundleId = runningApp?.bundleIdentifier
            if let bundleId, blockList.blocks(bundleId) {
                continue
            }
            let ownerName = (info[kCGWindowOwnerName as String] as? String)
                ?? runningApp?.localizedName
                ?? bundleId
                ?? "PID-\(ownerPid)"
            let title = info[kCGWindowName as String] as? String

            var windowDict: [String: Any] = [
                "id": windowId,
                "app": ownerName,
            ]
            if let bundleId { windowDict["bundleIdentifier"] = bundleId }
            if let title, !title.isEmpty { windowDict["title"] = title }
            if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: boundsDict) {
                windowDict["bounds"] = [
                    "x": Double(rect.origin.x),
                    "y": Double(rect.origin.y),
                    "width": Double(rect.size.width),
                    "height": Double(rect.size.height),
                ]
            }
            results.append(windowDict)
        }
        return results
    }

    private func collectWindowsByPid(blocking blockList: AppBlockList) -> [pid_t: [[String: Any]]] {
        guard let all = try? listWindows(appFilter: nil, blocking: blockList) else { return [:] }
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }
        var pidByWindowId: [Int: pid_t] = [:]
        for info in windowInfoList {
            if let wid = info[kCGWindowNumber as String] as? Int,
               let pid = info[kCGWindowOwnerPID as String] as? pid_t {
                pidByWindowId[wid] = pid
            }
        }
        var map: [pid_t: [[String: Any]]] = [:]
        for w in all {
            if let wid = w["id"] as? Int, let pid = pidByWindowId[wid] {
                map[pid, default: []].append(w)
            }
        }
        return map
    }

    public func primaryWindowInfo(for pid: pid_t) -> (windowId: Int, bounds: CGRect)? {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for info in windowInfoList {
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0,
                  let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid == pid,
                  let wid = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.width > 16,
                  rect.height > 16 else {
                continue
            }
            return (windowId: wid, bounds: rect)
        }
        return nil
    }

    /// Walks the app's tree and replaces the element cache. The returned text
    /// is only a header: the plugin numbers elements itself from `rawTree`,
    /// so the helper must not print its own element numbers.
    ///
    /// Element bounds in `rawTree` are window-local points (relative to the
    /// window's top-left corner), the same space action coordinates use. An
    /// app without an on-screen window reports screen coordinates and no
    /// `window_bounds`.
    public func captureAppState(
        appIdentifier: String,
        blocking blockList: AppBlockList
    ) throws -> (app: NSRunningApplication, rawTree: [String: Any], formattedText: String, windowId: Int, windowBounds: CGRect?) {
        let app = try resolveApplication(appIdentifier, blocking: blockList)
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        // Enable accessibility trees for Chromium / Electron / WebKit apps
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let primaryWin = primaryWindowInfo(for: pid)
        let windowId = primaryWin?.windowId ?? 0
        let windowBounds = primaryWin?.bounds

        let origin = windowBounds?.origin ?? .zero
        var cache = AppElementCache(windowId: windowId, windowOrigin: origin)
        var counter = 0
        walkTimeouts = 0

        let rootSnapshot = try walkElement(
            element: axApp,
            pid: pid,
            path: [],
            origin: origin,
            depth: 0,
            counter: &counter,
            cache: &cache
        )
        appCaches[pid] = cache

        let displayName = app.localizedName ?? app.bundleIdentifier ?? appIdentifier
        var header = "App: \(displayName) (pid: \(pid), window: \(windowId))"
        if let wb = windowBounds {
            header += " bounds=(\(Int(wb.origin.x)),\(Int(wb.origin.y)),\(Int(wb.size.width))x\(Int(wb.size.height)))"
        }

        var rawTree: [String: Any] = [
            "window_id": windowId,
        ]
        if let windowBounds {
            rawTree["window_bounds"] = AXBoundsSnapshot(
                x: Double(windowBounds.origin.x),
                y: Double(windowBounds.origin.y),
                width: Double(windowBounds.width),
                height: Double(windowBounds.height)
            ).toDictionary()
        }
        if let rootSnapshot {
            rawTree["root"] = rootSnapshot.toDictionary()
        }
        if let focused = copyFocusedElementNativeId(axApp: axApp, cache: cache) {
            rawTree["focused_element"] = focused
        }
        return (
            app: app,
            rawTree: rawTree,
            formattedText: header,
            windowId: windowId,
            windowBounds: windowBounds
        )
    }

    /// The window an action targets, with its current bounds: the window of
    /// the latest snapshot, or the app's primary window when no snapshot
    /// exists. Window-local coordinates mean nothing without an on-screen
    /// window, so a minimized, closed, or other-Space window is an error and
    /// never a made-up rectangle.
    public func currentWindow(pid: pid_t) throws -> (windowId: Int, bounds: CGRect) {
        if let cache = appCaches[pid], cache.windowId > 0 {
            if let bounds = Self.onScreenBounds(windowId: cache.windowId) {
                return (cache.windowId, bounds)
            }
            throw HelperError(
                code: HelperError.accessibilityError,
                message: "The app's window is minimized, closed, or on another Space. Show the window, then call get_app_state again."
            )
        }
        if let primary = primaryWindowInfo(for: pid) {
            return primary
        }
        throw HelperError(
            code: HelperError.accessibilityError,
            message: "The app has no window on the current Space. Show a window, then call get_app_state again."
        )
    }

    /// The window id to focus before keyboard input, or 0 when the app has no
    /// usable window. Keyboard events go to the process, so they do not need
    /// window coordinates.
    public func focusWindowId(pid: pid_t) -> Int {
        (try? currentWindow(pid: pid))?.windowId ?? 0
    }

    /// The bounds of one window while it is on screen in the current Space.
    static func onScreenBounds(windowId: Int) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowId)
        ) as? [[String: Any]],
              let info = infoList.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowId }),
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict) else {
            return nil
        }
        return rect
    }

    /// Returns the element only when it still exists and still matches the
    /// signature the calling agent saw (`expected`). Another agent's read of
    /// the same app replaces the cache, so the cache's own record cannot be
    /// trusted for this check. The returned frame is read live, so a caller
    /// never acts on coordinates from an old snapshot.
    public func resolveLiveElement(
        pid: pid_t,
        nativeId: String,
        expected: Any?
    ) throws -> (element: AXUIElement, frame: AXBoundsSnapshot?) {
        guard let expectedSignature = ElementSignature(dictionary: expected) else {
            throw HelperError(
                code: HelperError.malformedRequest,
                message: "Missing or invalid 'expected' signature for element '\(nativeId)'; call get_app_state again."
            )
        }
        guard ElementNativeId.ownerPid(of: nativeId) == pid else {
            throw HelperError(
                code: HelperError.staleElement,
                message: "Element '\(nativeId)' does not belong to this app; call get_app_state again."
            )
        }
        guard let element = appCaches[pid]?.byNativeId[nativeId] else {
            throw HelperError(
                code: HelperError.staleElement,
                message: "Element '\(nativeId)' is not in the latest accessibility snapshot; call get_app_state again."
            )
        }
        // The agent saw window-local frames. Comparing against the window's
        // current origin keeps elements valid when only the window moved.
        let origin: CGPoint
        if let cache = appCaches[pid], cache.windowId > 0,
           let bounds = Self.onScreenBounds(windowId: cache.windowId) {
            origin = bounds.origin
        } else {
            origin = appCaches[pid]?.windowOrigin ?? .zero
        }
        guard let live = Self.readSignature(element, origin: origin) else {
            throw HelperError(
                code: HelperError.staleElement,
                message: "Element '\(nativeId)' no longer exists; call get_app_state again."
            )
        }
        guard expectedSignature.matches(live) else {
            throw HelperError(
                code: HelperError.staleElement,
                message: "Element '\(nativeId)' changed since the latest snapshot; call get_app_state again."
            )
        }
        return (element, Self.copyBounds(element))
    }

    /// Reads the identity attributes of a live element. A missing role means
    /// the element was destroyed (AX returns an invalid-element error).
    public static func readSignature(_ element: AXUIElement, origin: CGPoint) -> ElementSignature? {
        guard let role = copyStringAttribute(element, kAXRoleAttribute) else {
            return nil
        }
        let title = copyStringAttribute(element, kAXTitleAttribute)
        let identifier = copyStringAttribute(element, "AXIdentifier")
        return ElementSignature(
            role: role,
            subrole: copyStringAttribute(element, kAXSubroleAttribute),
            name: title ?? identifier,
            frame: copyBounds(element)?.relative(to: origin)
        )
    }

    /// The app's focused element, used to read a text field back after typing.
    public static func focusedElement(pid: pid_t) -> AXUIElement? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    private func copyFocusedElementNativeId(axApp: AXUIElement, cache: AppElementCache) -> String? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            return nil
        }
        let focusedElement = focused as! AXUIElement
        for (nativeId, element) in cache.byNativeId {
            if CFEqual(focusedElement, element) {
                return nativeId
            }
        }
        return nil
    }

    private func walkElement(
        element: AXUIElement,
        pid: pid_t,
        path: [Int],
        origin: CGPoint,
        depth: Int,
        counter: inout Int,
        cache: inout AppElementCache
    ) throws -> AXNodeSnapshot? {
        if depth > Self.maxTraversalDepth || counter >= Self.maxNodeCount {
            return nil
        }
        try CommandCancellation.checkCurrent()

        counter += 1
        // The child-index path keeps an element's id the same across snapshots
        // while the tree shape is unchanged.
        let nativeId = ElementNativeId.make(pid: pid, path: path)

        var roleRef: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if roleError == .cannotComplete {
            walkTimeouts += 1
            // An unresponsive root means the whole app is hung; a few
            // unresponsive children mean the same thing for this walk.
            if depth == 0 || walkTimeouts >= Self.maxWalkTimeouts {
                throw HelperError(
                    code: HelperError.accessibilityError,
                    message: "The app is not responding to accessibility requests. Try again later."
                )
            }
        }
        let role = (roleRef as? String) ?? "AXElement"
        let subrole = Self.copyStringAttribute(element, kAXSubroleAttribute)
        let title = Self.copyStringAttribute(element, kAXTitleAttribute)
        let desc = Self.copyStringAttribute(element, kAXDescriptionAttribute)
        let identifier = Self.copyStringAttribute(element, "AXIdentifier")

        let isSecure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        let rawValue = Self.copyValueString(element)
        let value = isSecure ? (rawValue != nil ? "••••••••" : nil) : rawValue

        let bounds = Self.copyBounds(element)?.relative(to: origin)
        let states = Self.copyStates(element, isSecure: isSecure)
        let actions = Self.copyActions(element)

        let name = title ?? identifier
        cache.byNativeId[nativeId] = element

        var childSnapshots: [AXNodeSnapshot] = []
        if depth < Self.maxTraversalDepth && counter < Self.maxNodeCount {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for (childIndex, child) in children.enumerated() {
                    if counter >= Self.maxNodeCount { break }
                    if let snap = try walkElement(
                        element: child,
                        pid: pid,
                        path: path + [childIndex],
                        origin: origin,
                        depth: depth + 1,
                        counter: &counter,
                        cache: &cache
                    ) {
                        childSnapshots.append(snap)
                    }
                }
            }
        }

        return AXNodeSnapshot(
            nativeId: nativeId,
            role: role,
            subrole: subrole,
            name: name,
            nodeDescription: desc,
            value: value,
            bounds: bounds,
            states: states,
            actions: actions,
            children: childSnapshots
        )
    }

    public static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let val = ref else {
            return nil
        }
        if let str = val as? String {
            return str
        }
        if let url = val as? URL {
            return url.absoluteString
        }
        return nil
    }

    public static func copyValueString(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
              let val = ref else {
            return nil
        }
        if let str = val as? String {
            return str
        }
        if let num = val as? NSNumber {
            return num.stringValue
        }
        return nil
    }

    public static func copyBounds(_ element: AXUIElement) -> AXBoundsSnapshot? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz) else {
            return nil
        }
        return AXBoundsSnapshot(
            x: Double(pt.x),
            y: Double(pt.y),
            width: Double(sz.width),
            height: Double(sz.height)
        )
    }

    public static func copyStates(_ element: AXUIElement, isSecure: Bool) -> [String] {
        var states: [String] = []
        if isSecure {
            states.append("secure")
        }
        var enabledRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           let enabled = enabledRef as? Bool {
            states.append(enabled ? "enabled" : "disabled")
        }
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef as? Bool, focused {
            states.append("focused")
        }
        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &selectedRef) == .success,
           let selected = selectedRef as? Bool, selected {
            states.append("selected")
        }
        return states
    }

    public static func copyActions(_ element: AXUIElement) -> [String] {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else {
            return []
        }
        return names
    }
}
