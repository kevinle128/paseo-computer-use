import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct HelperError: Error, Sendable {
    public let code: String
    public let message: String
    /// The `user_focus_changed` line of an action that changed the app in
    /// front and then failed. It travels with the error so the audit log
    /// still records it.
    public var userFocusChanged: String?
    /// The input idle times behind a focus watch outcome in
    /// `userFocusChanged`, for the audit log only.
    public var focusWatchDetail: String?
    /// The window a `window_gone` error is about, as data so the plugin does
    /// not read it out of the message.
    public var windowId: Int?
    /// The bundle id an `app_blocked` error refused, as data so the plugin
    /// does not read it out of the message.
    public var bundleId: String?
    /// The input idle times behind a `user_active` refusal, for the audit
    /// log only. The message the agent reads has no numbers.
    public var userActivityDetail: String?

    public init(
        code: String,
        message: String,
        userFocusChanged: String? = nil,
        focusWatchDetail: String? = nil,
        windowId: Int? = nil,
        bundleId: String? = nil,
        userActivityDetail: String? = nil
    ) {
        self.code = code
        self.message = message
        self.userFocusChanged = userFocusChanged
        self.focusWatchDetail = focusWatchDetail
        self.windowId = windowId
        self.bundleId = bundleId
        self.userActivityDetail = userActivityDetail
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
    /// A macOS permission the command needs is not granted. Not transient: the
    /// same command fails until the user grants it.
    public static let permissionMissing = "permission_missing"
    /// The window the agent named (or read last) is closed, minimized, on
    /// another Space, or belongs to another app. The command stops instead of
    /// acting on a different window.
    public static let windowGone = "window_gone"
    /// The user pressed a key, a mouse button, or scrolled a moment ago, so
    /// an action that sends input or changes an element was refused before
    /// it did anything.
    public static let userActive = "user_active"
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
    /// What the selected attribute read, set only for a menu bar item. `states`
    /// lists "selected" when it is on and says nothing when it is off, so this
    /// is how the plugin tells an item that reports the attribute (off) from
    /// one that does not report it at all.
    public let selected: Bool?
    public let actions: [String]
    public let children: [AXNodeSnapshot]
    /// The CG window id of an `AXWindow` node, so the plugin can tell which
    /// window a node is without matching frames.
    public var windowId: Int? = nil

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
        if let selected { dict["selected"] = selected }
        if let windowId { dict["window_id"] = windowId }
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

    private var appCaches = CacheSlots<AppElementCache>()

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
            guard let candidate = Self.reportableWindow(info),
                  let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            let windowId = candidate.id
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
            windowDict["bounds"] = [
                "x": Double(candidate.bounds.origin.x),
                "y": Double(candidate.bounds.origin.y),
                "width": Double(candidate.bounds.size.width),
                "height": Double(candidate.bounds.size.height),
            ]
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

    /// A window that list_windows reports and that a default choice may
    /// pick: a normal-layer window with some opacity and a usable size. One
    /// filter serves both, so the two always agree.
    public struct WindowCandidate: Equatable {
        public var id: Int
        public var bounds: CGRect
        public var title: String?
        /// The window server layer: 0 for a normal window, above 0 for a
        /// floating, utility, or modal panel.
        public var layer: Int

        public init(id: Int, bounds: CGRect, title: String? = nil, layer: Int = 0) {
            self.id = id
            self.bounds = bounds
            self.title = title
            self.layer = layer
        }
    }

    static func reportableWindow(_ info: [String: Any]) -> WindowCandidate? {
        let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
        let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
        guard layer == 0,
              alpha > 0,
              let wid = info[kCGWindowNumber as String] as? Int,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict),
              rect.width > 16,
              rect.height > 16 else {
            return nil
        }
        return WindowCandidate(id: wid, bounds: rect, title: info[kCGWindowName as String] as? String)
    }

    /// The layers of a panel an app can own: above the normal windows and
    /// below the menu bar. The menu bar, status items, and popup menus sit
    /// higher and are not windows an agent reads.
    static var panelLayers: Range<Int> {
        1..<Int(CGWindowLevelForKey(.mainMenuWindow))
    }

    /// The first layer of an app-modal panel (an alert or a modal dialog).
    static var modalPanelLayer: Int {
        Int(CGWindowLevelForKey(.modalPanelWindow))
    }

    /// A floating, utility, or modal panel: a window above layer 0 with some
    /// opacity and a usable size. An agent can read one with `window_id`.
    static func panelWindow(_ info: [String: Any]) -> WindowCandidate? {
        let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
        let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
        guard panelLayers.contains(layer),
              alpha > 0,
              let wid = info[kCGWindowNumber as String] as? Int,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict),
              rect.width > 16,
              rect.height > 16 else {
            return nil
        }
        return WindowCandidate(id: wid, bounds: rect, title: info[kCGWindowName as String] as? String, layer: layer)
    }

    /// Whether a focused panel may take keys meant for the target: it is an
    /// app-modal panel (an alert the app is waiting on) above the target.
    /// A floating palette that happens to be key is another window.
    static func panelTakesKeys(panelLayer: Int, targetLayer: Int, axModal: Bool) -> Bool {
        panelLayer > targetLayer && (axModal || panelLayer >= modalPanelLayer)
    }

    /// The default window among `candidates` (front to back): the one the app
    /// calls focused, else the one it calls main, else the largest. A hint
    /// names a window by frame and title, and a hint that matches no
    /// candidate is skipped, so a window list_windows would not report is
    /// never chosen.
    static func chooseWindow(candidates: [WindowCandidate], hints: [WindowCandidate]) -> WindowCandidate? {
        for hint in hints {
            let sameFrame = candidates.filter { Self.framesMatch($0.bounds, hint.bounds) }
            if let match = sameFrame.first(where: { $0.title == hint.title }) ?? sameFrame.first {
                return match
            }
        }
        // `max` keeps the first of equal areas, so the frontmost wins a tie.
        var best: WindowCandidate?
        for candidate in candidates {
            if best == nil || candidate.bounds.width * candidate.bounds.height > best!.bounds.width * best!.bounds.height {
                best = candidate
            }
        }
        return best
    }

    /// Two frames from different APIs may round differently, so a point of
    /// difference still names the same window.
    private static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= 1 && abs(a.origin.y - b.origin.y) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    /// The frame and title of the app's AXFocusedWindow, then AXMainWindow.
    private func axWindowHints(pid: pid_t) -> [WindowCandidate] {
        let axApp = AXUIElementCreateApplication(pid)
        var hints: [WindowCandidate] = []
        for attribute in ["AXFocusedWindow", "AXMainWindow"] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &ref) == .success,
                  let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
                continue
            }
            let window = ref as! AXUIElement
            guard let box = Self.copyBounds(window) else { continue }
            hints.append(WindowCandidate(
                id: 0,
                bounds: CGRect(x: box.x, y: box.y, width: box.width, height: box.height),
                title: Self.copyStringAttribute(window, kAXTitleAttribute)
            ))
        }
        return hints
    }

    /// The app's windows that list_windows reports, front to back.
    public func reportableWindows(pid: pid_t) -> [WindowCandidate] {
        windows(pid: pid).filter { $0.layer == 0 }
    }

    /// The app's on-screen windows, front to back: the ones list_windows
    /// reports and its floating, utility, and modal panels.
    func windows(pid: pid_t) -> [WindowCandidate] {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windowInfoList.compactMap { info -> WindowCandidate? in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
            return Self.reportableWindow(info) ?? Self.panelWindow(info)
        }
    }

    public func primaryWindowInfo(for pid: pid_t) -> (windowId: Int, bounds: CGRect)? {
        let candidates = reportableWindows(pid: pid)
        guard !candidates.isEmpty,
              let chosen = Self.chooseWindow(candidates: candidates, hints: axWindowHints(pid: pid)) else {
            return nil
        }
        return (windowId: chosen.id, bounds: chosen.bounds)
    }

    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// `_AXUIElementGetWindow` is the exact link from an AX window to its
    /// window server id. It is not public API, so it is looked up at run time
    /// and a missing symbol falls back to matching frame and title.
    private static let axGetWindowFn: AXGetWindowFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: AXGetWindowFn.self)
    }()

    /// The window of `candidates` a probe with this frame and title names, or
    /// nil. Two windows with the same frame and title cannot be told apart,
    /// and a frame shared by differently titled windows needs the title.
    static func matchWindow(frame: CGRect, title: String?, in candidates: [WindowCandidate]) -> WindowCandidate? {
        let sameFrame = candidates.filter { framesMatch($0.bounds, frame) }
        let sameTitle = sameFrame.filter { $0.title == title }
        if sameTitle.count == 1 {
            return sameTitle.first
        }
        return sameTitle.isEmpty && sameFrame.count == 1 ? sameFrame.first : nil
    }

    /// The window server id of an AX window element from the exact link only,
    /// or nil when the symbol is missing or the element is not a window.
    static func exactWindowId(of element: AXUIElement) -> Int? {
        guard let fn = axGetWindowFn else { return nil }
        var id: CGWindowID = 0
        guard fn(element, &id) == .success, id != 0 else { return nil }
        return Int(id)
    }

    /// The window server id of an AX window element, or nil when it is not a
    /// window of `candidates`.
    static func windowId(of element: AXUIElement, among candidates: [WindowCandidate]) -> Int? {
        if let id = exactWindowId(of: element) {
            return id
        }
        guard let box = copyBounds(element) else { return nil }
        let frame = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        return matchWindow(frame: frame, title: copyStringAttribute(element, kAXTitleAttribute), in: candidates)?.id
    }

    /// The title list_windows shows for a window, which is the one the plugin
    /// prints everywhere. The window server's title has no profile or app
    /// suffix; it is missing without the Screen Recording permission, and then
    /// the AX title stands in.
    static func displayTitle(window: WindowCandidate, axTitle: String?) -> String {
        if let title = window.title, !title.isEmpty {
            return title
        }
        return axTitle ?? ""
    }

    /// The id and title of the app's AXFocusedWindow when it is one of the
    /// windows list_windows reports.
    public func focusedWindow(pid: pid_t) -> (id: Int, title: String)? {
        let candidates = reportableWindows(pid: pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), "AXFocusedWindow" as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        let window = ref as! AXUIElement
        guard let id = Self.windowId(of: window, among: candidates),
              let entry = candidates.first(where: { $0.id == id }) else {
            return nil
        }
        return (id, Self.displayTitle(window: entry, axTitle: Self.copyStringAttribute(window, kAXTitleAttribute)))
    }

    /// What an app says about its key window, compared with the window a key
    /// is meant for.
    public enum FocusedWindowState: Equatable {
        /// AXFocusedWindow is the target, or a sheet of it.
        case belongs
        /// AXFocusedWindow is another window.
        case elsewhere
        /// The app does not report AXFocusedWindow (Java, Qt, some Electron
        /// builds, games): nothing can be compared.
        case unreported
        /// The app did not answer within the time limit of the check (a
        /// hung or very slow app).
        case noAnswer
    }

    /// The answer of one key window check and what is needed to act on it.
    public struct KeyWindowCheck: Equatable {
        public var state: FocusedWindowState
        /// The target is the only window the app has on screen, so a key has
        /// no other window to go to.
        public var targetIsOnlyWindow: Bool
        /// The window the app reported as focused, when it is one of its
        /// windows. Only for the refusal text.
        public var focusedWindowId: Int?

        public init(state: FocusedWindowState, targetIsOnlyWindow: Bool, focusedWindowId: Int? = nil) {
            self.state = state
            self.targetIsOnlyWindow = targetIsOnlyWindow
            self.focusedWindowId = focusedWindowId
        }

        /// Keys may be sent. An app that does not report its focused window
        /// is trusted only when it has one window, which is then the target.
        public var allowsKeys: Bool {
            switch state {
            case .belongs: return true
            case .elsewhere, .noAnswer: return false
            case .unreported: return targetIsOnlyWindow
            }
        }
    }

    /// Whether the app's AXFocusedWindow is the window `windowId`, or a sheet
    /// of it: a sheet is the app's key window while it is open, and keys go to
    /// it on purpose. `checkpoint` runs before each accessibility request, so
    /// a cancel or a time limit stops the check between two requests to a
    /// slow app instead of after all of them.
    public func keyWindowCheck(
        pid: pid_t,
        target windowId: Int,
        checkpoint: () throws -> Void = { try CommandCancellation.checkCurrent() }
    ) throws -> KeyWindowCheck {
        let all = windows(pid: pid)
        let candidates = all.filter { $0.layer == 0 }
        let onlyWindow = candidates.count == 1 && candidates[0].id == windowId
        var ref: CFTypeRef?
        try checkpoint()
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), "AXFocusedWindow" as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            // An app that is not in front can report no focused window at
            // all: AppKit has no key window for an inactive app. The target's
            // own flags then decide.
            let held = try Self.targetHoldsKey(state: .unreported, focusedIsOrdinary: false) {
                try self.targetWindowFlags(pid: pid, target: windowId, among: all, checkpoint: checkpoint)
            }
            return KeyWindowCheck(state: held ? .belongs : .unreported, targetIsOnlyWindow: onlyWindow)
        }
        let window = ref as! AXUIElement
        try checkpoint()
        let focusedId = Self.windowId(of: window, among: all)
        if focusedId == windowId {
            return KeyWindowCheck(state: .belongs, targetIsOnlyWindow: onlyWindow, focusedWindowId: focusedId)
        }
        var state = FocusedWindowState.elsewhere
        try checkpoint()
        let isSheet = Self.copyStringAttribute(window, kAXRoleAttribute) == "AXSheet"
        func isModal() throws -> Bool {
            try checkpoint()
            return Self.copyBoolAttribute(window, "AXModal") == true
        }
        if let focusedId, let panel = all.first(where: { $0.id == focusedId }), panel.layer > 0,
           Self.panelTakesKeys(
               panelLayer: panel.layer,
               targetLayer: all.first(where: { $0.id == windowId })?.layer ?? 0,
               axModal: try isModal()
           ) {
            state = .belongs
        } else if isSheet {
            var parentRef: CFTypeRef?
            try checkpoint()
            if AXUIElementCopyAttributeValue(window, kAXParentAttribute as CFString, &parentRef) == .success,
               let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID() {
                try checkpoint()
                if Self.windowId(of: parentRef as! AXUIElement, among: all) == windowId {
                    state = .belongs
                }
            }
        }
        if state == .elsewhere {
            // The app-level answer can lag or stay stale for an app that is
            // not in front. It is set aside only for another ordinary window;
            // a panel or a sheet of another window keeps the keys.
            let ordinary = focusedId.flatMap { id in all.first(where: { $0.id == id }) }.map { $0.layer == 0 } == true
                && !isSheet
            if try Self.targetHoldsKey(state: .elsewhere, focusedIsOrdinary: ordinary, flags: {
                try self.targetWindowFlags(pid: pid, target: windowId, among: all, checkpoint: checkpoint)
            }) {
                state = .belongs
            }
        }
        return KeyWindowCheck(state: state, targetIsOnlyWindow: onlyWindow, focusedWindowId: focusedId)
    }

    /// The target window's own AXFocused and AXMain, which the app keeps for
    /// each window whether or not the app is in front.
    struct TargetWindowFlags: Equatable {
        var focused: Bool?
        var main: Bool?
    }

    /// Whether the target window itself says it is the app's key window, for
    /// the cases where the app-level AXFocusedWindow says nothing, or names
    /// another ordinary window while the app is not in front. `flags` is only
    /// read when it can change the answer.
    static func targetHoldsKey(
        state: FocusedWindowState,
        focusedIsOrdinary: Bool,
        flags: () throws -> TargetWindowFlags?
    ) rethrows -> Bool {
        switch state {
        case .belongs: return true
        case .noAnswer: return false
        case .elsewhere where !focusedIsOrdinary: return false
        case .elsewhere, .unreported:
            guard let flags = try flags() else { return false }
            return flags.focused == true || flags.main == true
        }
    }

    /// The AX window of the app whose window server id is `windowId`.
    private func axWindow(
        pid: pid_t,
        target windowId: Int,
        among all: [WindowCandidate],
        checkpoint: () throws -> Void
    ) rethrows -> AXUIElement? {
        var ref: CFTypeRef?
        try checkpoint()
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        for window in windows {
            try checkpoint()
            if Self.windowId(of: window, among: all) == windowId { return window }
        }
        return nil
    }

    /// The close button Command+w stands for in a window it could not reach.
    public enum CommandWButton {
        /// The window's own close button: no tab bar, or one tab.
        case window(AXUIElement)
        /// The close button of the window's selected tab.
        case tab(AXUIElement)
        /// No button closes only what Command+w would close.
        case none
    }

    /// The accessibility reads of `CloseControl`.
    static let closeControlTree = CloseControl<AXUIElement>.Tree(
        role: { copyStringAttribute($0, kAXRoleAttribute) },
        subrole: { copyStringAttribute($0, kAXSubroleAttribute) },
        names: { [copyStringAttribute($0, kAXTitleAttribute), copyStringAttribute($0, kAXDescriptionAttribute)].compactMap { $0 } },
        isSelected: { copyValueString($0) == "1" || copyBoolAttribute($0, kAXSelectedAttribute) == true },
        children: { copyChildren($0) }
    )

    /// Which close button stands for Command+w in the window `windowId`
    /// (see `CloseControl`). `checkpoint` runs before each accessibility
    /// request and its error is passed on.
    public func commandWButton(pid: pid_t, windowId: Int, checkpoint: () throws -> Void) throws -> CommandWButton {
        guard let window = try axWindow(pid: pid, target: windowId, among: windows(pid: pid), checkpoint: checkpoint) else {
            return .none
        }
        switch try CloseControl.decide(window: window, tree: Self.closeControlTree, checkpoint: checkpoint) {
        case .refuse:
            return .none
        case .tab(let button):
            return .tab(button)
        case .window:
            var ref: CFTypeRef?
            try checkpoint()
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &ref) == .success,
                  let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return .none }
            return .window(ref as! AXUIElement)
        }
    }

    private func targetWindowFlags(
        pid: pid_t,
        target windowId: Int,
        among all: [WindowCandidate],
        checkpoint: () throws -> Void
    ) throws -> TargetWindowFlags? {
        guard let window = try axWindow(pid: pid, target: windowId, among: all, checkpoint: checkpoint) else { return nil }
        try checkpoint()
        let focused = Self.copyBoolAttribute(window, kAXFocusedAttribute)
        try checkpoint()
        let main = Self.copyBoolAttribute(window, kAXMainAttribute)
        return TargetWindowFlags(focused: focused, main: main)
    }

    /// Which top-level children of the app element a read walks: the menu bar,
    /// the target window, and the windows that belong to it (sheets and
    /// popups that are windows of their own and sit over the target, and
    /// panels over it). The other windows, panels that do not cover the
    /// target included, are only listed, with no elements.
    final class WindowScope {
        let targetId: Int
        let targetBounds: CGRect
        let candidates: [WindowCandidate]
        private var otherIds: [Int: String] = [:]
        private(set) var targetSeen = false
        /// Windows that are not minimized and have no window server id.
        private(set) var unidentified = 0

        init(targetId: Int, targetBounds: CGRect, candidates: [WindowCandidate]) {
            self.targetId = targetId
            self.targetBounds = targetBounds
            self.candidates = candidates
        }

        /// Other windows, front to back.
        var others: [(id: Int, title: String)] {
            candidates.compactMap { candidate in otherIds[candidate.id].map { (candidate.id, $0) } }
        }

        /// Whether windows that cannot be told apart hid the target: the read
        /// would have no window in it and no reason. An app that lists no
        /// window at all is a sparse app and is not an error.
        static func hidTarget(targetSeen: Bool, unidentified: Int) -> Bool {
            !targetSeen && unidentified > 0
        }

        var hidTarget: Bool {
            Self.hidTarget(targetSeen: targetSeen, unidentified: unidentified)
        }

        /// A panel that covers the target is read with it.
        static func isWalkedPanel(_ window: WindowCandidate, over targetBounds: CGRect) -> Bool {
            window.layer > 0 && window.bounds.intersects(targetBounds)
        }

        /// Roles a suggestion dropdown is built from. Anything with a button,
        /// a text field, or another control in it can be a prompt (a
        /// permission or save-password bubble) and is never one of these.
        private static let dropdownRoles: Set<String> = ["AXList", "AXRow", "AXCell", "AXStaticText"]

        /// An untitled window under the target's toolbar that holds only a
        /// list of rows, such as a browser's address suggestion dropdown. It
        /// opens and closes with each keystroke, so it is left out of the
        /// opened and closed windows of a change report. It is still walked
        /// (when it covers the target) like any other window: this only says
        /// the window is not worth reporting as a change. An app-modal panel
        /// (an alert) is never one, and neither is a window with no children
        /// the helper could read.
        static func isSuggestionDropdown(
            _ window: WindowCandidate,
            over targetBounds: CGRect,
            childRoles: () -> [String]
        ) -> Bool {
            guard window.id > 0,
                  (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  window.layer < AXEngine.modalPanelLayer else {
                return false
            }
            let toolbarArea = CGRect(
                x: targetBounds.minX,
                y: targetBounds.minY,
                width: targetBounds.width,
                height: min(targetBounds.height, max(160, targetBounds.height * 0.25))
            )
            guard window.bounds.intersects(toolbarArea) else { return false }
            let roles = childRoles()
            return !roles.isEmpty && roles.allSatisfy(dropdownRoles.contains)
        }

        /// Ids of windows that match `isSuggestionDropdown`, whether the read
        /// walked them or not. The plugin leaves them out of change reports.
        private(set) var dropdownIds: [Int] = []

        func idOf(_ window: AXUIElement) -> Int? {
            AXEngine.windowId(of: window, among: candidates)
        }

        func admits(_ child: AXUIElement) -> Bool {
            guard AXEngine.copyStringAttribute(child, kAXRoleAttribute) == "AXWindow" else {
                return true
            }
            let title = AXEngine.copyStringAttribute(child, kAXTitleAttribute)
            let childId = idOf(child)
            if childId == nil, AXEngine.copyBoolAttribute(child, "AXMinimized") != true {
                unidentified += 1
            }
            if let id = childId {
                if id == targetId {
                    targetSeen = true
                    return true
                }
                if let listed = candidates.first(where: { $0.id == id }) {
                    let dropdown = Self.isSuggestionDropdown(listed, over: targetBounds) {
                        AXEngine.copyChildren(child).compactMap { AXEngine.copyStringAttribute($0, kAXRoleAttribute) }
                    }
                    if dropdown { dropdownIds.append(id) }
                    // A panel over the target is part of what the agent sees
                    // (an alert it must answer); any other window is listed.
                    if Self.isWalkedPanel(listed, over: targetBounds) {
                        return true
                    }
                    if dropdown { return false }
                    otherIds[id] = AXEngine.displayTitle(window: listed, axTitle: title)
                    return false
                }
            }
            // Not a listed window: minimized, on another Space, or a sheet or
            // popup window. Only the last kind, over the target, is walked.
            if AXEngine.copyBoolAttribute(child, "AXMinimized") == true
                || AXEngine.copyStringAttribute(child, kAXSubroleAttribute) == "AXStandardWindow" {
                return false
            }
            guard let box = AXEngine.copyBounds(child) else { return false }
            return CGRect(x: box.x, y: box.y, width: box.width, height: box.height).intersects(targetBounds)
        }
    }

    /// Walks the app's menu bar and one window and replaces the element cache.
    /// The window is `windowId` when given (a window that is not an open window
    /// of the app throws `window_gone`), else the app's own pick. The other
    /// windows of the app are listed in `other_windows` and not walked, so the
    /// tree stays the size of one window. The returned text is only a header:
    /// the plugin numbers elements itself from `rawTree`, so the helper must
    /// not print its own element numbers.
    ///
    /// Element bounds in `rawTree` are window-local points (relative to the
    /// window's top-left corner), the same space action coordinates use. An
    /// app without an on-screen window reports screen coordinates and no
    /// `window_bounds`.
    ///
    /// `updateCache: false` reads the tree without touching the element cache
    /// or the cached window, for reads the agent did not ask for (the state
    /// before an action, the polls of a wait). The agent's next action still
    /// resolves elements and the window against its own last read.
    public func captureAppState(
        appIdentifier: String,
        blocking blockList: AppBlockList,
        updateCache: Bool = true,
        windowId requestedWindowId: Int? = nil
    ) throws -> (app: NSRunningApplication, rawTree: [String: Any], formattedText: String, windowId: Int, windowBounds: CGRect?) {
        let app = try resolveApplication(appIdentifier, blocking: blockList)
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        // Enable accessibility trees for Chromium / Electron / WebKit apps
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        // The panels are windows an agent can name with `window_id`, but the
        // app's own pick is always a normal window.
        let candidates = windows(pid: pid)
        let primaryWin: (windowId: Int, bounds: CGRect)?
        if let requestedWindowId, requestedWindowId > 0 {
            guard let entry = candidates.first(where: { $0.id == requestedWindowId }) else {
                throw Self.windowGoneError(requestedWindowId)
            }
            primaryWin = (entry.id, entry.bounds)
        } else {
            primaryWin = primaryWindowInfo(for: pid)
        }
        let windowId = primaryWin?.windowId ?? 0
        let windowBounds = primaryWin?.bounds

        let origin = windowBounds?.origin ?? .zero
        var cache = AppElementCache(windowId: windowId, windowOrigin: origin)
        var counter = 0
        walkTimeouts = 0

        // An app with no on-screen window has nothing to scope: its tree is
        // read whole, as before.
        let scope = windowBounds.map { WindowScope(targetId: windowId, targetBounds: $0, candidates: candidates) }
        let rootSnapshot = try walkElement(
            element: axApp,
            pid: pid,
            path: [],
            origin: origin,
            depth: 0,
            counter: &counter,
            cache: &cache,
            scope: scope
        )
        if let scope, scope.hidTarget {
            throw HelperError(
                code: HelperError.accessibilityError,
                message: "Window \(windowId) cannot be told apart from the app's other windows: the app gives no window ids and they share a frame and title. Close the other windows of the app, or read it with a screenshot and coordinates."
            )
        }
        appCaches.store(cache, for: pid, replace: updateCache)

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
        // The title the window server shows, when it reports one.
        if let title = candidates.first(where: { $0.id == windowId })?.title, !title.isEmpty {
            rawTree["window_title"] = title
        }
        if let scope {
            rawTree["other_windows"] = scope.others.map { ["id": $0.id, "title": $0.title] as [String: Any] }
            if !scope.dropdownIds.isEmpty {
                rawTree["dropdown_windows"] = scope.dropdownIds
            }
        }
        if let focused = focusedWindow(pid: pid) {
            rawTree["focused_window"] = ["id": focused.id, "title": focused.title] as [String: Any]
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

    static func windowGoneError(_ windowId: Int) -> HelperError {
        HelperError(
            code: HelperError.windowGone,
            message: "Window \(windowId) is closed, minimized, on another Space, or not a window of this app. Call get_app_state to read a window that is open.",
            windowId: windowId
        )
    }

    /// The window an image comparison reads: `windowId` when it is one of the
    /// app's own windows, else the app's main window. A window of another app
    /// is refused, so a window id cannot reach around the block list.
    public func captureWindow(
        appIdentifier: String,
        windowId: Int?,
        blocking blockList: AppBlockList
    ) throws -> (windowId: Int, bounds: CGRect) {
        let app = try resolveApplication(appIdentifier, blocking: blockList)
        if let windowId {
            let windows = try listWindows(appFilter: appIdentifier, blocking: blockList)
            guard let entry = windows.first(where: { ($0["id"] as? Int) == windowId }),
                  let box = entry["bounds"] as? [String: Any],
                  let x = (box["x"] as? NSNumber)?.doubleValue,
                  let y = (box["y"] as? NSNumber)?.doubleValue,
                  let width = (box["width"] as? NSNumber)?.doubleValue,
                  let height = (box["height"] as? NSNumber)?.doubleValue else {
                throw HelperError(
                    code: HelperError.malformedRequest,
                    message: "Window \(windowId) is not an open window of this app. Call list_windows to see its windows."
                )
            }
            return (windowId, CGRect(x: x, y: y, width: width, height: height))
        }
        guard let primary = primaryWindowInfo(for: app.processIdentifier) else {
            throw HelperError(
                code: HelperError.accessibilityError,
                message: "The app has no window on the current Space. Show a window and try again."
            )
        }
        return primary
    }

    /// The window an action targets, with its current bounds: `requested` when
    /// the command names one, else the window of the latest snapshot, else the
    /// app's primary window. Window-local coordinates mean nothing without an
    /// on-screen window, so a minimized, closed, other-Space, or other-app
    /// window is an error (`window_gone` for a named window) and never a
    /// made-up rectangle or another window.
    public func currentWindow(pid: pid_t, requested: Int? = nil) throws -> (windowId: Int, bounds: CGRect) {
        if let requested, requested > 0 {
            if let bounds = Self.onScreenBounds(windowId: requested, ownerPid: pid) {
                return (requested, bounds)
            }
            throw Self.windowGoneError(requested)
        }
        if let cache = appCaches[pid], cache.windowId > 0 {
            if let bounds = Self.onScreenBounds(windowId: cache.windowId, ownerPid: pid) {
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

    /// The window id keyboard input goes to, or 0 when the app has no usable
    /// window. Keyboard events go to the process, so they do not need window
    /// coordinates. A named window that is gone is an error, never another
    /// window. Without a named window the target is the window of the latest
    /// read; when that window is gone the command stops with `window_gone`
    /// and sends nothing.
    public func focusWindowId(pid: pid_t, requested: Int? = nil) throws -> Int {
        if let requested, requested > 0 {
            return try currentWindow(pid: pid, requested: requested).windowId
        }
        let cachedId = appCaches[pid]?.windowId
        let cachedOnScreen = cachedId.map { $0 > 0 && Self.onScreenBounds(windowId: $0, ownerPid: pid) != nil } ?? false
        return try Self.defaultKeyWindow(
            cachedId: cachedId,
            cachedOnScreen: cachedOnScreen,
            primaryId: cachedOnScreen ? nil : primaryWindowInfo(for: pid)?.windowId
        )
    }

    /// The default key window: the window of the latest read while it is on
    /// screen, `window_gone` when that window has closed, else the app's own
    /// pick, else 0 for an app with no window.
    static func defaultKeyWindow(cachedId: Int?, cachedOnScreen: Bool, primaryId: Int?) throws -> Int {
        if let cachedId, cachedId > 0 {
            if cachedOnScreen {
                return cachedId
            }
            throw windowGoneError(cachedId)
        }
        return primaryId ?? 0
    }

    /// The bounds of one window while it is on screen in the current Space,
    /// and, when `ownerPid` is given, only if that process owns it.
    static func onScreenBounds(windowId: Int, ownerPid: pid_t? = nil) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowId)
        ) as? [[String: Any]],
              let info = infoList.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowId }),
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              ownerPid == nil || (info[kCGWindowOwnerPID as String] as? pid_t) == ownerPid,
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
        expected: Any?,
        windowId: Int? = nil
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
        // The cache holds the latest read of the app by any agent. An element
        // from a read of another window is not an element of the window the
        // agent is acting in.
        if let windowId, windowId > 0, let cached = appCaches[pid]?.windowId, cached > 0, cached != windowId {
            throw HelperError(
                code: HelperError.staleElement,
                message: "Element '\(nativeId)' belongs to window \(cached), not window \(windowId); call get_app_state for window \(windowId)."
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
        cache: inout AppElementCache,
        scope: WindowScope? = nil
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
        let states = Self.copyStates(element, role: role, isSecure: isSecure)
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
                    // Child indexes keep counting the windows left out, so an
                    // element's id does not depend on the scope.
                    if depth == 0, let scope, !scope.admits(child) { continue }
                    if let snap = try walkElement(
                        element: child,
                        pid: pid,
                        path: path + [childIndex],
                        origin: origin,
                        depth: depth + 1,
                        counter: &counter,
                        cache: &cache,
                        scope: scope
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
            selected: role == "AXMenuBarItem" ? Self.copyBoolAttribute(element, kAXSelectedAttribute) : nil,
            actions: actions,
            children: childSnapshots,
            windowId: depth == 1 && role == "AXWindow" ? scope?.idOf(element) : nil
        )
    }

    public static func copyBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? Bool
    }

    /// Whether the element no longer exists in its app.
    static func isGone(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref) == .invalidUIElement
    }

    /// The direct children of an element, or none when it reports none.
    static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else {
            return []
        }
        return children
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

    /// Roles whose AXValue is 1 while they are on (checked, selected, toggled).
    private static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"]

    public static func copyStates(_ element: AXUIElement, role: String, isSecure: Bool) -> [String] {
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
        var expandedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXExpandedAttribute as CFString, &expandedRef) == .success,
           let expanded = expandedRef as? Bool, expanded {
            states.append("expanded")
        }
        if role == "AXMenuItem",
           let markState = MenuItemMark.state(for: copyStringAttribute(element, "AXMenuItemMarkChar")) {
            states.append(markState)
        }
        if toggleRoles.contains(role), !isSecure,
           let value = copyValueString(element), value == "1" {
            states.append("checked")
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
