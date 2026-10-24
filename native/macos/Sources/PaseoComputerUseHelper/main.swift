import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
#if canImport(PaseoComputerUseCore)
import PaseoComputerUseCore
#endif

private let writeLock = NSLock()

private func sendJSONLine(_ dict: [String: Any]) {
    writeLock.lock()
    defer { writeLock.unlock() }
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
          var line = String(data: data, encoding: .utf8) else {
        return
    }
    line.append("\n")
    if let outData = line.data(using: .utf8) {
        FileHandle.standardOutput.write(outData)
    }
}

private func sendResponse(id: Int, result: Any) {
    sendJSONLine([
        "id": id,
        "ok": true,
        "result": result,
    ])
}

private func sendError(id: Int, code: String, message: String) {
    sendJSONLine([
        "id": id,
        "ok": false,
        "error": [
            "code": code,
            "message": message,
        ],
    ])
}

/// Tokens of commands that are queued or running, by request id. A `cancel`
/// message cancels one token; an Escape or takeover abort cancels all of
/// them, so queued commands are dropped instead of running after the stop.
private final class CommandRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int: CommandCancellation] = [:]

    func register(_ id: Int) -> CommandCancellation {
        let token = CommandCancellation()
        lock.lock()
        tokens[id] = token
        lock.unlock()
        return token
    }

    func remove(_ id: Int) {
        lock.lock()
        tokens[id] = nil
        lock.unlock()
    }

    /// Returns false when no queued or running command has this id.
    func cancel(_ id: Int) -> Bool {
        lock.lock()
        let token = tokens[id]
        lock.unlock()
        token?.cancel()
        return token != nil
    }

    func cancelAll() {
        lock.lock()
        let all = Array(tokens.values)
        lock.unlock()
        for token in all {
            token.cancel()
        }
    }
}

private let commandRegistry = CommandRegistry()

/// Commands that touch other apps run here, one at a time. The main thread
/// stays free for the Escape event tap and the overlay, so a long action or a
/// hung app never blocks the user's input or the stop key.
private let commandQueue = DispatchQueue(label: "paseo.computer-use.commands", qos: .userInitiated)

private let escapeMonitor = UserInputEscapeMonitor { reason in
    commandRegistry.cancelAll()
    let message: String
    switch reason {
    case .escapeKey:
        message = "Computer Use was stopped by the user with the physical Escape key."
    case .userIntervened:
        message = "Computer Use was paused because the user took control of the mouse pointer."
    }
    sendJSONLine([
        "event": "abort",
        "reason": reason.rawValue,
        "message": message,
    ])
    Task { @MainActor in
        OverlayPresenter.shared.hide()
    }
}

/// Commands that only change helper state. They run on the main thread, which
/// owns the event tap, and never wait behind a running action.
private let controlCommands: Set<String> = ["cancel", "end_turn", "abort_tap.arm", "abort_tap.disarm"]

@MainActor
private func dispatchControlCommand(cmd: String, params: [String: Any]) throws -> Any {
    switch cmd {
    case "cancel":
        guard let requestId = (params["requestId"] as? NSNumber)?.intValue else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'requestId' parameter.")
        }
        return ["cancelled": commandRegistry.cancel(requestId)]

    case "end_turn":
        // The plugin sends this whenever the agent gives the computer back:
        // the overlay fades out. The Escape tap stays armed: the plugin's
        // control lock owns it and disarms it when it releases the computer.
        OverlayPresenter.shared.hide()
        return ["ok": true]

    case "abort_tap.arm":
        let armed = escapeMonitor.arm()
        return ["armed": armed]

    case "abort_tap.disarm":
        escapeMonitor.disarm()
        return ["armed": false]

    default:
        throw HelperError(code: HelperError.unknownCommand, message: "Unknown command '\(cmd)'.")
    }
}

private func dispatchCommand(cmd: String, params: [String: Any]) throws -> Any {
    switch cmd {
    case "status":
        let axTrusted = AXIsProcessTrusted()
        let screenCaptureGranted = CGPreflightScreenCaptureAccess()
        let inputStatus = InputDriver.shared.currentInputSource()
        let helperHash = ProcessInfo.processInfo.environment["PASEO_HELPER_SOURCE_HASH"] ?? "native"
        return [
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "axTrusted": axTrusted,
            "screenCaptureGranted": screenCaptureGranted,
            "abortTapAvailable": axTrusted,
            "inputSourceId": inputStatus.inputSourceId,
            "isInputMethod": inputStatus.isInputMethod,
            "helperSourceHash": helperHash,
        ]

    case "list_apps":
        return AXEngine.shared.listApps(blocking: try AppBlockList(params: params))

    case "list_windows":
        let appFilter = params["app"] as? String
        return try AXEngine.shared.listWindows(appFilter: appFilter, blocking: try AppBlockList(params: params))

    case "get_app_state":
        guard let appName = params["app"] as? String else {
            throw HelperError(code: HelperError.malformedRequest, message: "Missing 'app' parameter.")
        }
        let includeScreenshot = (params["includeScreenshot"] as? Bool) ?? true

        // Diffing and query filtering happen in the plugin on its own
        // numbered text, so the helper always returns the full raw tree.
        let captured = try AXEngine.shared.captureAppState(
            appIdentifier: appName,
            blocking: try AppBlockList(params: params)
        )

        var windowState: [String: Any] = [
            "text": captured.formattedText,
            "rawTree": captured.rawTree,
        ]
        if includeScreenshot,
           let screenshot = ScreenCapture.shared.captureWindowScreenshot(
               windowId: captured.windowId,
               windowBounds: captured.windowBounds
           ) {
            windowState["screenshot"] = screenshot
        } else {
            windowState["screenshot"] = NSNull()
        }

        let appDescriptor: Any
        if let bundleId = captured.app.bundleIdentifier {
            appDescriptor = [
                "bundleIdentifier": bundleId,
                "displayName": captured.app.localizedName ?? appName,
            ]
        } else {
            appDescriptor = captured.app.localizedName ?? appName
        }

        return [
            "app": appDescriptor,
            "windowState": windowState,
        ]

    case "click":
        return try InputDriver.shared.performClick(params: params)

    case "drag":
        return try InputDriver.shared.performDrag(params: params)

    case "scroll":
        return try InputDriver.shared.performScroll(params: params)

    case "press_key":
        return try InputDriver.shared.performPressKey(params: params)

    case "type_text":
        return try InputDriver.shared.performTypeText(params: params)

    case "paste_text":
        return try InputDriver.shared.performPasteText(params: params)

    case "set_value":
        return try InputDriver.shared.performSetValue(params: params)

    case "select_text":
        return try InputDriver.shared.performSelectText(params: params)

    case "perform_secondary_action":
        return try InputDriver.shared.performSecondaryAction(params: params)

    default:
        throw HelperError(code: HelperError.unknownCommand, message: "Unknown command '\(cmd)'.")
    }
}

if CommandLine.arguments.contains("--mcp-proxy") {
    ProxyShim.run(arguments: Array(CommandLine.arguments.dropFirst()))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
AXEngine.configureMessagingTimeout()

private func reply(id: Int, _ body: () throws -> Any) {
    do {
        sendResponse(id: id, result: try body())
    } catch let err as HelperError {
        sendError(id: id, code: err.code, message: err.message)
    } catch {
        sendError(id: id, code: HelperError.internalError, message: error.localizedDescription)
    }
}

let stdinThread = Thread {
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendError(id: 0, code: HelperError.malformedRequest, message: "Malformed JSON request.")
            continue
        }

        let id = (json["id"] as? Int) ?? 0
        guard let cmd = json["cmd"] as? String else {
            sendError(id: id, code: HelperError.missingCommand, message: "Missing 'cmd' field.")
            continue
        }
        let params = (json["params"] as? [String: Any]) ?? [:]

        if controlCommands.contains(cmd) {
            DispatchQueue.main.async {
                reply(id: id) {
                    try MainActor.assumeIsolated {
                        try dispatchControlCommand(cmd: cmd, params: params)
                    }
                }
            }
            continue
        }

        // Registered before queueing so a cancel or abort that arrives while
        // the command waits drops it before it starts.
        let token = commandRegistry.register(id)
        commandQueue.async {
            defer { commandRegistry.remove(id) }
            reply(id: id) {
                try token.check()
                return try CommandCancellation.run(with: token) {
                    try dispatchCommand(cmd: cmd, params: params)
                }
            }
        }
    }
    DispatchQueue.main.async {
        exit(0)
    }
}
stdinThread.start()

RunLoop.main.run()
