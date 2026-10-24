import Foundation

/// What an element looked like when the agent last read the tree. An action
/// only goes ahead when the live element still looks the same, so a changed
/// or replaced element is never acted on by mistake.
public struct ElementSignature: Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let name: String?
    public let frame: AXBoundsSnapshot?

    /// Frames come from floating-point AX values; a small tolerance keeps
    /// sub-point rounding from reporting a live element as changed.
    public static let frameTolerance = 2.0

    public init(role: String, subrole: String?, name: String?, frame: AXBoundsSnapshot?) {
        self.role = role
        // The tree sent to the plugin omits empty strings, so an empty live
        // value must equal an absent one or every such element looks changed.
        self.subrole = (subrole?.isEmpty ?? true) ? nil : subrole
        self.name = (name?.isEmpty ?? true) ? nil : name
        self.frame = frame
    }

    /// Reads the signature the plugin sends with an element action: the
    /// role, subrole, name, and frame the agent saw in its own latest read.
    /// Returns nil when the value is missing or has no role.
    public init?(dictionary value: Any?) {
        guard let dict = value as? [String: Any],
              let role = dict["role"] as? String, !role.isEmpty else {
            return nil
        }
        var frame: AXBoundsSnapshot?
        if let rawFrame = dict["frame"] {
            guard let f = rawFrame as? [String: Any],
                  let x = (f["x"] as? NSNumber)?.doubleValue,
                  let y = (f["y"] as? NSNumber)?.doubleValue,
                  let width = (f["width"] as? NSNumber)?.doubleValue,
                  let height = (f["height"] as? NSNumber)?.doubleValue else {
                return nil
            }
            frame = AXBoundsSnapshot(x: x, y: y, width: width, height: height)
        }
        self.init(
            role: role,
            subrole: dict["subrole"] as? String,
            name: dict["name"] as? String,
            frame: frame
        )
    }

    public func matches(_ live: ElementSignature) -> Bool {
        guard role == live.role, subrole == live.subrole, name == live.name else {
            return false
        }
        switch (frame, live.frame) {
        case (nil, nil):
            return true
        case let (cached?, current?):
            let t = Self.frameTolerance
            return abs(cached.x - current.x) <= t
                && abs(cached.y - current.y) <= t
                && abs(cached.width - current.width) <= t
                && abs(cached.height - current.height) <= t
        default:
            return false
        }
    }
}

/// Element ids carry the owning process, so an id read from one app can never
/// address an element in another app that happens to share the same tree path.
public enum ElementNativeId {
    public static func make(pid: pid_t, path: [Int]) -> String {
        "\(pid):" + path.map(String.init).joined(separator: ".")
    }

    public static func ownerPid(of nativeId: String) -> pid_t? {
        guard let colon = nativeId.firstIndex(of: ":") else { return nil }
        return pid_t(nativeId[nativeId.startIndex..<colon])
    }
}

/// Decides whether an action's effect was actually observed. Each helper
/// reports `verified` only after reading the effect back; anything else is
/// `unverified` with a reason the agent can act on.
public enum ActionVerification {
    public static func verified(_ reason: String) -> [String: Any] {
        ["state": "verified", "reason": reason]
    }

    public static func unverified(_ reason: String) -> [String: Any] {
        ["state": "unverified", "reason": reason]
    }

    /// Text entry (typing or pasting) is verified when the field value changed
    /// and now contains the entered text. An input method that rewrites the
    /// text, or a field that ignores the events, is reported as unverified.
    public static func textEntry(before: String?, after: String?, entered: String) -> [String: Any] {
        guard let after else {
            return unverified("could not read the field value after entering text")
        }
        if let before, before == after {
            return unverified("field value did not change")
        }
        if !after.contains(entered) {
            return unverified("field value does not contain the entered text")
        }
        return verified("field_value_read_back")
    }

    public static func setValue(requested: String, readBack: String?) -> [String: Any] {
        guard let readBack else {
            return unverified("could not read the value back after setting it")
        }
        if readBack != requested {
            return unverified("value read back differs from the requested value")
        }
        return verified("value_read_back")
    }

    public static func selection(requested: CFRange, readBack: CFRange?) -> [String: Any] {
        guard let readBack else {
            return unverified("could not read the selection back")
        }
        if readBack.location != requested.location || readBack.length != requested.length {
            return unverified("selection read back differs from the requested range")
        }
        return verified("selection_read_back")
    }
}
