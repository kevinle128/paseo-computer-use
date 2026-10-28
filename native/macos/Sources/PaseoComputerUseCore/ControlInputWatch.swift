import Foundation

/// The Escape stop key: a tap that watches key presses and pointer moves
/// while an agent controls the computer.
public protocol StopKeyWatch: AnyObject {
    /// Returns false when the tap cannot be created (no Accessibility).
    func arm() -> Bool
    func disarm()
}

/// The click and scroll log that the pause check reads.
public protocol PointerInputWatch: AnyObject {
    @MainActor func start()
    /// Also drops what the log holds.
    @MainActor func stop()
}

extension UserInputEscapeMonitor: StopKeyWatch {}

/// Runs the input watches only while an agent controls the computer.
///
/// The plugin arms the stop key when an agent takes control for an action,
/// and disarms it when control ends: the turn ends, the user presses Stop,
/// the connection closes, or the owner is idle. The click and scroll log
/// follows the same span, so a status check or the settings screen never
/// starts it, and it never starts while Computer Use is off (turning Computer
/// Use off during control ends it with control). An Escape press
/// or a mouse shake stops the log at once; the plugin then releases control
/// and disarms the stop key.
public final class ControlInputWatch {
    private let stopKey: StopKeyWatch
    private let inputLog: PointerInputWatch

    public init(stopKey: StopKeyWatch, inputLog: PointerInputWatch) {
        self.stopKey = stopKey
        self.inputLog = inputLog
    }

    /// An agent took control. Arms the stop key, then starts the log. The
    /// plugin may ask again while the key is armed; the log then keeps
    /// running, or starts again after an Escape stopped it.
    @MainActor
    public func arm() -> Bool {
        guard stopKey.arm() else { return false }
        inputLog.start()
        return true
    }

    /// Control ended.
    @MainActor
    public func disarm() {
        stopKey.disarm()
        inputLog.stop()
    }

    /// The user pressed Escape or shook the mouse.
    @MainActor
    public func userStopped() {
        inputLog.stop()
    }
}
