import CoreGraphics
import Foundation
import XCTest
@testable import PaseoComputerUseCore

/// A fake desktop for focus corrections: a fake clock, a fake front process,
/// a fake holder of the keyboard, a fake screen update hold with a watchdog
/// that tests fire by hand, and fake window server and activation calls.
/// Nothing here reads or changes the real screen, apps, or input.
final class FakeDesktop {
    var time = 100.0
    /// The window server's front process.
    var front: FrontmostGuard.App?
    /// AppKit's frontmost app follows the window server unless a test holds
    /// it at `appKitFront`.
    var appKitFollows = true
    var appKitFront: FrontmostGuard.App?

    func readAppKitFront() -> FrontmostGuard.App? {
        appKitFollows ? front : appKitFront
    }
    var keyHolder: FrontmostGuard.App?
    var keyHolderReads = 0

    func readKeyHolder() -> FrontmostGuard.App? {
        keyHolderReads += 1
        return keyHolder
    }
    /// Every step, in order, for checks of the sequence.
    var log: [String] = []

    /// The screen update hold exists. When false, the correction has no gate.
    var holdAvailable = true
    var holdAccepted = true
    /// Seconds the fake clock moves while a window request runs, to model a
    /// slow step inside the hold.
    var windowRequestTakes = 0.0
    var watchdogs: [(delay: Double, fire: () -> Void)] = []
    var holds = 0
    var releases = 0

    /// The window server request with a window id exists and is accepted.
    var windowRequestAvailable = true
    var windowRequestTakesEffect = true
    var keyRecordsAvailable = true
    /// The key window records move the keyboard to their window.
    var keyRecordsTakeEffect = true
    /// A menu or popover is open in the app with this pid. A window request,
    /// an activation, or a raise sent to that app closes it.
    var menuOpenInPid: pid_t?
    var menuIsOpen: Bool { menuOpenInPid != nil }

    private func touch(_ pid: pid_t) {
        if menuOpenInPid == pid { menuOpenInPid = nil }
    }
    var activateResult = true
    var activationTakesEffect = true
    /// Another window of the user's app is above the user's window.
    var userWindowBuried = false
    /// What a read of the user's window gives now.
    var userWindowId: Int? = 7
    var userWindowReads = 0
    var reassertResult = true

    var activations: [FrontmostGuard.App] = []
    var windowRequests: [(pid: pid_t, windowId: Int)] = []
    var keyRecords: [(pid: pid_t, windowId: Int)] = []
    var reasserted: [pid_t] = []
    var raised: [(pid: pid_t, windowId: Int)] = []

    /// Fakes of every app this desktop knows, by pid.
    var apps: [pid_t: FrontmostGuard.App] = [:]

    func gate() -> ScreenUpdateGate? {
        guard holdAvailable else { return nil }
        return ScreenUpdateGate(
            primitives: ScreenUpdateGate.Primitives(
                hold: {
                    self.log.append("hold")
                    guard self.holdAccepted else { return false }
                    self.holds += 1
                    return true
                },
                release: {
                    self.log.append("release")
                    self.releases += 1
                }
            ),
            now: { self.time },
            watchdog: { delay, fire in self.watchdogs.append((delay, fire)) }
        )
    }

    func correction() -> FocusCorrection {
        FocusCorrection(
            gate: gate(),
            reassertTarget: { pid in
                self.log.append("reassert \(pid)")
                self.reasserted.append(pid)
                return self.reassertResult
            },
            requestFront: { pid, windowId in
                self.log.append("window request \(pid) [\(windowId)]")
                // A step that stalls this long lets the watchdog thread fire
                // on time, while the step still runs.
                let start = self.time
                for watchdog in self.watchdogs where watchdog.delay <= self.windowRequestTakes {
                    self.time = start + watchdog.delay
                    watchdog.fire()
                }
                self.time = start + self.windowRequestTakes
                guard self.windowRequestAvailable else { return false }
                self.touch(pid)
                self.windowRequests.append((pid, windowId))
                if self.windowRequestTakesEffect, let app = self.apps[pid] {
                    self.front = app
                }
                return true
            },
            postKeyRecords: { pid, windowId in
                self.log.append("key records \(pid) [\(windowId)]")
                guard self.keyRecordsAvailable else { return false }
                self.keyRecords.append((pid, windowId))
                if self.keyRecordsTakeEffect, let app = self.apps[pid] { self.keyHolder = app }
                return true
            },
            activate: { app in
                self.log.append("activate \(app.pid)")
                self.activations.append(app)
                if self.activateResult { self.touch(app.pid) }
                if self.activateResult && self.activationTakesEffect { self.front = app }
                return self.activateResult
            },
            raiseIfBuried: { pid, windowId in
                self.log.append("raise check \(pid) [\(windowId)]")
                guard self.userWindowBuried else { return false }
                self.touch(pid)
                self.raised.append((pid, windowId))
                return true
            },
            readUserWindowId: { _ in
                self.userWindowReads += 1
                return self.userWindowId
            }
        )
    }
}

final class ScreenUpdateGateTests: XCTestCase {
    private struct Boom: Error {}

    private func gate(_ desktop: FakeDesktop) throws -> ScreenUpdateGate {
        try XCTUnwrap(desktop.gate())
    }

    func testTheHoldIsReleasedWhenTheBodyEnds() throws {
        let desktop = FakeDesktop()
        let (value, report) = try gate(desktop).run { () -> Int in
            desktop.log.append("body")
            desktop.time += 0.012
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(desktop.log, ["hold", "body", "release"])
        XCTAssertEqual(report, ScreenUpdateGate.Report(heldMs: 12, releasedBy: .body))
        XCTAssertEqual(desktop.watchdogs.first?.delay, ScreenUpdateGate.capSeconds)
    }

    func testTheHoldIsReleasedWhenTheBodyThrows() throws {
        let desktop = FakeDesktop()
        XCTAssertThrowsError(try gate(desktop).run { () throws -> Int in throw Boom() })
        XCTAssertEqual(desktop.holds, 1)
        XCTAssertEqual(desktop.releases, 1)
    }

    func testTheWatchdogReleasesABodyThatRunsPastTheCapAndTheBodyThenReleasesNothing() throws {
        let desktop = FakeDesktop()
        let (_, report) = try gate(desktop).run { () -> Void in
            // The body stalls: the watchdog fires on its own thread first.
            desktop.time += ScreenUpdateGate.capSeconds
            desktop.watchdogs.first?.fire()
            XCTAssertEqual(desktop.releases, 1, "released while the body still runs")
            desktop.time += 0.5
        }
        XCTAssertEqual(desktop.releases, 1, "never released twice")
        XCTAssertEqual(report, ScreenUpdateGate.Report(heldMs: 250, releasedBy: .watchdog, overCap: false))
    }

    func testALateWatchdogReportsTheRealHoldAndThatItWentOverTheCap() throws {
        let desktop = FakeDesktop()
        let (_, report) = try gate(desktop).run { () -> Void in
            desktop.time += 0.4
            desktop.watchdogs.first?.fire()
        }
        XCTAssertEqual(report, ScreenUpdateGate.Report(heldMs: 400, releasedBy: .watchdog, overCap: true))
    }

    func testAWatchdogThatFiresAfterTheBodyReleasesNothing() throws {
        let desktop = FakeDesktop()
        _ = try gate(desktop).run { desktop.time += 0.01 }
        desktop.time += 1
        desktop.watchdogs.first?.fire()
        XCTAssertEqual(desktop.releases, 1)
    }

    func testABodyThatEndsPastTheCapBeforeTheWatchdogReportsTheRealHold() throws {
        let desktop = FakeDesktop()
        // A clock that jumps past the cap before the watchdog had a chance.
        let (_, report) = try gate(desktop).run { desktop.time += 3 }
        XCTAssertEqual(report, ScreenUpdateGate.Report(heldMs: 3000, releasedBy: .body, overCap: true))
    }

    func testARefusedHoldRunsTheBodyWithNothingToRelease() throws {
        let desktop = FakeDesktop()
        desktop.holdAccepted = false
        var ran = false
        let (_, report) = try gate(desktop).run { ran = true }
        XCTAssertTrue(ran)
        XCTAssertNil(report)
        XCTAssertEqual(desktop.releases, 0)
        XCTAssertTrue(desktop.watchdogs.isEmpty)
    }

    /// Records the window server calls of a test with real time: when each
    /// began and ended, on which thread, and how many ran at once.
    private final class CallProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maxActive = 0
        private(set) var calls: [(name: String, start: Double, end: Double, onMain: Bool)] = []

        func call(_ name: String, lasting seconds: Double = 0) {
            let start = ProcessInfo.processInfo.systemUptime
            lock.lock()
            active += 1
            maxActive = max(maxActive, active)
            lock.unlock()
            if seconds > 0 { usleep(UInt32(seconds * 1_000_000)) }
            lock.lock()
            active -= 1
            calls.append((name, start, ProcessInfo.processInfo.systemUptime, Thread.isMainThread))
            lock.unlock()
        }

        func named(_ name: String) -> [(name: String, start: Double, end: Double, onMain: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return calls.filter { $0.name == name }
        }
    }

    private func liveWatchdogGate(_ probe: CallProbe, calls: WindowServerCalls) -> ScreenUpdateGate {
        ScreenUpdateGate(
            primitives: WindowServer.serializedPrimitives(
                hold: { probe.call("hold"); return true },
                release: { probe.call("release") },
                calls: calls
            ),
            now: { ProcessInfo.processInfo.systemUptime },
            watchdog: ScreenUpdateGate.queueWatchdog
        )
    }

    func testTheLiveWatchdogReleasesAtTheCapWhileTheMainThreadIsStalled() {
        // Real time, fake hold and release: the body stalls the main thread
        // well past the cap and the watchdog must not wait for it.
        let probe = CallProbe()
        let gate = liveWatchdogGate(probe, calls: WindowServerCalls())
        let start = ProcessInfo.processInfo.systemUptime
        var bodyRanOnMain = false
        let (_, report) = gate.run {
            bodyRanOnMain = Thread.isMainThread
            usleep(600_000)
        }
        let bodyEnd = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(bodyRanOnMain)
        let releases = probe.named("release")
        XCTAssertEqual(releases.count, 1, "released once, and not again at the end of the body")
        guard let release = releases.first else { return }
        XCTAssertFalse(release.onMain)
        XCTAssertLessThan(release.end - start, ScreenUpdateGate.capSeconds + 0.2)
        XCTAssertLessThan(release.end, bodyEnd - 0.2, "released while the body still ran")
        XCTAssertEqual(report?.releasedBy, .watchdog)
    }

    func testTheWatchdogReleaseNeverRunsAtTheSameTimeAsAnotherWindowServerCall() {
        // Real time, fake calls. The main thread is inside a window server
        // call when the cap passes, and a command thread posts records
        // through the hold: the release waits for the call in flight, runs
        // alone, and still comes before the body ends.
        let probe = CallProbe()
        let calls = WindowServerCalls()
        let gate = liveWatchdogGate(probe, calls: calls)
        let commandThreadDone = DispatchSemaphore(value: 0)
        let stop = NSLock()
        var stopped = false
        DispatchQueue.global().async {
            while true {
                stop.lock()
                let done = stopped
                stop.unlock()
                if done { break }
                calls.run { probe.call("key records", lasting: 0.005) }
                usleep(1_000)
            }
            commandThreadDone.signal()
        }
        let (_, report) = gate.run {
            usleep(200_000)
            calls.run { probe.call("window request", lasting: 0.2) }
            usleep(200_000)
        }
        let bodyEnd = ProcessInfo.processInfo.systemUptime
        stop.lock()
        stopped = true
        stop.unlock()
        XCTAssertEqual(commandThreadDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(probe.maxActive, 1, "two window server calls ran at once")
        XCTAssertFalse(probe.named("key records").isEmpty)
        guard let request = probe.named("window request").first, let release = probe.named("release").first else {
            return XCTFail("the request or the release did not run")
        }
        XCTAssertGreaterThanOrEqual(release.start, request.end, "the release waited for the call in flight")
        XCTAssertLessThan(release.end, bodyEnd - 0.1, "released before the body ended")
        XCTAssertFalse(release.onMain)
        XCTAssertEqual(report?.releasedBy, .watchdog)
        XCTAssertEqual(report?.overCap, true, "the hold is measured to the end of the late release")
    }

    func testTheCapIs250Ms() {
        XCTAssertEqual(ScreenUpdateGate.capSeconds, 0.25)
    }
}

final class FocusCorrectionTests: XCTestCase {
    private let editor = FrontmostGuard.App(pid: 10, label: "com.example.editor")
    private let browser = FrontmostGuard.App(pid: 20, label: "com.example.browser")

    private func desktop() -> FakeDesktop {
        let desktop = FakeDesktop()
        desktop.apps = [10: editor, 20: browser]
        desktop.front = browser
        return desktop
    }

    func testTheStepsRunInsideTheHoldInOrder() {
        let desktop = desktop()
        let steps = desktop.correction().bringBack(user: editor, targetPid: 20)
        XCTAssertEqual(desktop.log, ["hold", "reassert 20", "window request 10 [7]", "key records 10 [7]", "release"])
        XCTAssertEqual(steps.path, .frontProcess)
        XCTAssertTrue(steps.targetReasserted)
        XCTAssertTrue(steps.keyFocusReturned)
        XCTAssertEqual(steps.gate?.releasedBy, .body)
        XCTAssertTrue(desktop.activations.isEmpty)
        XCTAssertEqual(desktop.front, editor)
    }

    func testWithoutTheHoldTheStepsRunWithoutAGate() {
        let desktop = desktop()
        desktop.holdAvailable = false
        let steps = desktop.correction().bringBack(user: editor, targetPid: 20)
        XCTAssertNil(steps.gate)
        XCTAssertFalse(desktop.log.contains("hold"))
        XCTAssertEqual(steps.path, .frontProcess)
    }

    func testARefusedWindowRequestFallsBackToActivation() {
        let desktop = desktop()
        desktop.windowRequestAvailable = false
        let steps = desktop.correction().bringBack(user: editor, targetPid: 20)
        XCTAssertEqual(steps.path, .activate)
        XCTAssertEqual(desktop.activations, [editor])
        XCTAssertFalse(steps.keyFocusReturned)
        XCTAssertEqual(desktop.log.last, "release", "the fallback also runs inside the hold")
    }

    func testAnUnknownUserWindowUsesActivation() {
        let desktop = desktop()
        desktop.userWindowId = nil
        let steps = desktop.correction().bringBack(user: editor, targetPid: 20)
        XCTAssertEqual(steps.path, .activate)
        XCTAssertTrue(desktop.windowRequests.isEmpty)
    }

    func testTheUserWindowIsReadRightBeforeTheRequestsAndOutsideTheHold() {
        let desktop = desktop()
        // The user's app opened window 9 after the action started.
        desktop.userWindowId = 9
        var steps = desktop.correction().bringBack(user: editor, targetPid: 20)
        XCTAssertEqual(desktop.userWindowReads, 1)
        XCTAssertEqual(desktop.log, ["hold", "reassert 20", "window request 10 [9]", "key records 10 [9]", "release"])
        XCTAssertEqual(steps.userWindowId, 9)
        desktop.userWindowBuried = true
        desktop.correction().raiseUserWindow(user: editor, steps: &steps)
        XCTAssertEqual(desktop.raised.map(\.windowId), [9], "the raise names the window the request named")
        let keys = desktop.correction().returnKeyFocus(user: editor)
        XCTAssertEqual(keys.userWindowId, 9)
        XCTAssertEqual(desktop.keyRecords.last?.windowId, 9)
    }

    func testNoKeysAreAskedBackWhenTheUserWindowIsNotKnown() {
        let desktop = desktop()
        desktop.userWindowId = nil
        let steps = desktop.correction().returnKeyFocus(user: editor)
        XCTAssertEqual(steps.path, .none)
        XCTAssertTrue(desktop.log.isEmpty)
    }

    func testNothingAskedWhenEveryPathFails() {
        let desktop = desktop()
        desktop.windowRequestAvailable = false
        desktop.activateResult = false
        let steps = desktop.correction().bringBack(user: editor, targetPid: 20)
        XCTAssertEqual(steps.path, .none)
        XCTAssertEqual(desktop.releases, 1, "the hold is released on this path too")
    }

    func testTheTargetIsNeverActivated() {
        let desktop = desktop()
        desktop.windowRequestAvailable = false
        _ = desktop.correction().bringBack(user: editor, targetPid: 20)
        _ = desktop.correction().returnKeyFocus(user: editor)
        XCTAssertFalse(desktop.activations.contains { $0.pid == 20 })
        XCTAssertFalse(desktop.windowRequests.contains { $0.pid == 20 })
        XCTAssertFalse(desktop.keyRecords.contains { $0.pid == 20 })
    }

    func testKeyFocusIsGivenBackWithTheKeyRecordsAloneAndNoHold() {
        let desktop = desktop()
        desktop.front = editor
        desktop.keyHolder = browser
        desktop.menuOpenInPid = 10
        let steps = desktop.correction().returnKeyFocus(user: editor)
        XCTAssertEqual(desktop.log, ["key records 10 [7]"], "no window request and no activation for an app in front")
        XCTAssertEqual(steps.path, .keyRecords)
        XCTAssertTrue(steps.keyFocusReturned)
        XCTAssertNil(steps.gate)
        XCTAssertEqual(desktop.keyHolder, editor)
        XCTAssertTrue(desktop.menuIsOpen)
    }

    func testKeyFocusAsksNothingElseWhenTheKeyRecordsCannotBePosted() {
        let desktop = desktop()
        desktop.front = editor
        desktop.keyRecordsAvailable = false
        let steps = desktop.correction().returnKeyFocus(user: editor)
        XCTAssertEqual(steps.path, .none)
        XCTAssertTrue(desktop.windowRequests.isEmpty)
        XCTAssertTrue(desktop.activations.isEmpty)
    }

    func testTheKeyFocusEscalationUsesTheWindowRequestElseTheActivation() {
        let desktop = desktop()
        var steps = desktop.correction().returnKeyFocus(user: editor)
        desktop.correction().escalateKeyFocus(user: editor, steps: &steps)
        XCTAssertEqual(steps.path, .keyRecordsThenFrontProcess)
        XCTAssertEqual(desktop.windowRequests.map(\.pid), [10])
        let refused = self.desktop()
        refused.windowRequestAvailable = false
        var fallback = refused.correction().returnKeyFocus(user: editor)
        refused.correction().escalateKeyFocus(user: editor, steps: &fallback)
        XCTAssertEqual(fallback.path, .keyRecordsThenActivate)
        XCTAssertEqual(refused.activations, [editor])
    }

    func testTheUserWindowIsRaisedOnlyWhenBuried() {
        let desktop = desktop()
        let correction = desktop.correction()
        var steps = FocusCorrection.Steps()
        steps.userWindowId = 7
        correction.raiseUserWindow(user: editor, steps: &steps)
        XCTAssertFalse(steps.userWindowRaised)
        desktop.userWindowBuried = true
        correction.raiseUserWindow(user: editor, steps: &steps)
        XCTAssertTrue(steps.userWindowRaised)
        XCTAssertEqual(desktop.raised.map(\.windowId), [7])
        var none = FocusCorrection.Steps()
        correction.raiseUserWindow(user: editor, steps: &none)
        XCTAssertFalse(none.userWindowRaised)
    }

    func testTheAuditTextNamesEveryStep() {
        let steps = FocusCorrection.Steps(
            gate: ScreenUpdateGate.Report(heldMs: 14, releasedBy: .body),
            path: .frontProcess,
            targetReasserted: true,
            keyFocusReturned: true,
            userWindowRaised: false
        )
        XCTAssertEqual(
            steps.text,
            "gate_held_ms=14 gate_over_cap=false gate_released_by=body restore_path=front_process target_reasserted=true key_focus_returned=true user_window_raised=false"
        )
        XCTAssertEqual(
            FocusCorrection.Steps(path: .activate).text,
            "gate_held_ms=none gate_over_cap=none gate_released_by=none restore_path=activate target_reasserted=false key_focus_returned=false user_window_raised=false"
        )
    }
}

final class KeyFocusTests: XCTestCase {
    func testTheTopWindowIsTheFirstNormalWindowOfTheApp() {
        let list: [[String: Any]] = [
            [kCGWindowOwnerPID as String: pid_t(30), kCGWindowLayer as String: 0, kCGWindowNumber as String: 1],
            [kCGWindowOwnerPID as String: pid_t(10), kCGWindowLayer as String: 25, kCGWindowNumber as String: 2],
            [kCGWindowOwnerPID as String: pid_t(10), kCGWindowLayer as String: 0, kCGWindowNumber as String: 3],
            [kCGWindowOwnerPID as String: pid_t(10), kCGWindowLayer as String: 0, kCGWindowNumber as String: 4],
        ]
        XCTAssertEqual(KeyFocus.topWindowId(pid: 10, in: list), 3)
        XCTAssertNil(KeyFocus.topWindowId(pid: 20, in: list))
    }

    func testAnActionWithNoSyntheticActivationHasNothingToPostAgain() {
        // A new driver has posted nothing, so there is nothing to repeat and
        // nothing is sent.
        XCTAssertFalse(InputDriver().reassertSyntheticActivation(pid: 4242))
    }
}

final class BoundedReadTests: XCTestCase {
    private func queue() -> DispatchQueue {
        DispatchQueue(label: "test.bounded-read")
    }

    func testAFastReadGivesItsValue() {
        let reader = BoundedRead<Int32>(queue: queue(), wait: 1, read: { 42 })
        XCTAssertEqual(reader.read(), 42)
        XCTAssertEqual(reader.read(), 42)
    }

    func testAHungReadGivesNilAfterTheWaitAndStartsNoSecondRead() {
        let lock = NSLock()
        var reads = 0
        let release = DispatchSemaphore(value: 0)
        let reader = BoundedRead<Int32>(queue: queue(), wait: 0.02, read: {
            lock.lock()
            reads += 1
            lock.unlock()
            release.wait()
            return 7
        })
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(reader.read())
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5, "the caller waits only a short time")
        let again = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(reader.read(), "a read still runs, so this one gives nil at once")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - again, 0.015)
        lock.lock()
        XCTAssertEqual(reads, 1)
        lock.unlock()
        release.signal()
        // Once the hung read ends, reads work again.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var value: Int32?
        while value == nil, ProcessInfo.processInfo.systemUptime < deadline {
            release.signal()
            value = reader.read()
        }
        XCTAssertEqual(value, 7)
    }
}
