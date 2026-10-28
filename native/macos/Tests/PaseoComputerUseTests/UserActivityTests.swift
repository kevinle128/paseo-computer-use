import CoreGraphics
import XCTest
@testable import PaseoComputerUseCore

final class UserActivityTests: XCTestCase {
    private let target: pid_t = 100
    private let paseo: pid_t = 200
    private let editor: pid_t = 300
    private let now: Double = 1000

    /// The target's window, in the background, partly covered by Paseo.
    private var targetWindow: UserActivity.ScreenWindow {
        .init(pid: target, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    /// Paseo in front, covering the right part of the target's window.
    private var screen: [UserActivity.ScreenWindow] {
        [
            .init(pid: paseo, bounds: CGRect(x: 500, y: 0, width: 600, height: 600)),
            targetWindow,
            .init(pid: editor, bounds: CGRect(x: 0, y: 700, width: 800, height: 300)),
        ]
    }

    private let insideTarget = CGPoint(x: 100, y: 100)
    private let onPaseoOverTarget = CGPoint(x: 600, y: 100)
    private let insideEditor = CGPoint(x: 100, y: 800)

    private func idle(key: Double = .infinity, mouse: Double = .infinity, scroll: Double = .infinity) -> UserActivity.Idle {
        .init(keyDown: key, mouseDown: mouse, scroll: scroll)
    }

    /// An observation with a log that covered the whole window, a history
    /// where `frontmostBefore` was in front until `switchedAt` and
    /// `frontmost` after it, and the given pointer records.
    private func seen(
        _ idle: UserActivity.Idle,
        frontmost: pid_t?,
        frontmostBefore: pid_t? = nil,
        switchedAt: Double? = nil,
        pointer: [UserActivity.PointerInput] = [],
        logSince: Double? = 900,
        windows: (() -> [UserActivity.ScreenWindow])? = nil
    ) -> UserActivity.Observation {
        let screen = self.screen
        return UserActivity.Observation(
            now: now,
            idle: idle,
            frontmost: frontmost,
            frontmostAt: { uptime in
                if let switchedAt, uptime < switchedAt { return frontmostBefore }
                return frontmost
            },
            pointerInputs: pointer,
            pointerLogSince: logSince,
            windows: windows ?? { screen }
        )
    }

    private func click(_ point: CGPoint, ago: Double) -> UserActivity.PointerInput {
        .init(uptime: now - ago, location: point)
    }

    private func decide(_ observation: UserActivity.Observation) -> UserActivity.Reason? {
        UserActivity.decide(target: target, observation)
    }

    // MARK: Keys

    func testTypingInAnotherAppWhileTheTargetIsInTheBackgroundIsAllowed() {
        XCTAssertNil(decide(seen(idle(key: 0.2), frontmost: editor)))
        XCTAssertNil(decide(seen(idle(key: 1.0), frontmost: paseo)))
    }

    func testTypingWhileTheTargetIsFrontmostRefuses() {
        XCTAssertEqual(decide(seen(idle(key: 1.0), frontmost: target)), .keyFrontmost)
    }

    func testTypingInTheTargetBeforeSwitchingAwayRefuses() {
        // The key went to the target; the user switched to Paseo after it.
        let observation = seen(idle(key: 1.0), frontmost: paseo, frontmostBefore: target, switchedAt: now - 0.5)
        XCTAssertEqual(decide(observation), .keyWasFrontmost)
    }

    func testTypingInAnotherAppBeforeSwitchingToItIsJudgedByTheKeyTime() {
        // Paseo was in front at the key; the target came forward later.
        // The target is frontmost now, so the key rule still refuses.
        let observation = seen(idle(key: 1.0), frontmost: target, frontmostBefore: paseo, switchedAt: now - 0.5)
        XCTAssertEqual(decide(observation), .keyFrontmost)
    }

    func testOldKeysNeverCount() {
        XCTAssertNil(decide(seen(idle(key: 4.0), frontmost: target)))
        XCTAssertNil(decide(seen(idle(key: UserActivity.pauseSeconds), frontmost: target)))
    }

    // MARK: Pointer

    func testClickInsideTheBackgroundTargetsWindowRefuses() {
        let observation = seen(idle(mouse: 1.0), frontmost: paseo, pointer: [click(insideTarget, ago: 1.0)])
        XCTAssertEqual(decide(observation), .pointerWindow)
    }

    func testScrollOverTheBackgroundTargetsWindowRefuses() {
        let observation = seen(idle(scroll: 0.5), frontmost: editor, pointer: [click(insideTarget, ago: 0.5)])
        XCTAssertEqual(decide(observation), .pointerWindow)
    }

    func testClickElsewhereIsAllowed() {
        XCTAssertNil(decide(seen(idle(mouse: 1.0), frontmost: editor, pointer: [click(insideEditor, ago: 1.0)])))
        // A click on the desktop, outside every window, is allowed too.
        XCTAssertNil(decide(seen(idle(mouse: 1.0), frontmost: editor, pointer: [click(CGPoint(x: 5000, y: 5000), ago: 1.0)])))
    }

    func testClickElsewhereIsAllowedEvenWhileTheTargetIsFrontmost() {
        // The log saw where the click went, so the frontmost app does not
        // decide.
        let observation = seen(idle(mouse: 1.0), frontmost: target, pointer: [click(insideEditor, ago: 1.0)])
        XCTAssertNil(decide(observation))
    }

    func testPaseoApprovalIsAllowed() {
        // A click on Allow in a Paseo window that covers the target's window.
        let clickObservation = seen(idle(mouse: 0.3), frontmost: paseo, pointer: [click(onPaseoOverTarget, ago: 0.3)])
        XCTAssertNil(decide(clickObservation))
        // Return in Paseo to approve.
        XCTAssertNil(decide(seen(idle(key: 0.3), frontmost: paseo, frontmostBefore: paseo, switchedAt: now - 10)))
        // Both at once.
        let both = seen(idle(key: 0.2, mouse: 0.3), frontmost: paseo, pointer: [click(onPaseoOverTarget, ago: 0.3)])
        XCTAssertNil(decide(both))
    }

    func testAnEarlierClickInTheTargetStillCountsAfterALaterClickElsewhere() {
        let observation = seen(
            idle(mouse: 0.5),
            frontmost: paseo,
            pointer: [click(insideTarget, ago: 2.0), click(onPaseoOverTarget, ago: 0.5)]
        )
        XCTAssertEqual(decide(observation), .pointerWindow)
    }

    func testClicksOutsideThePauseWindowDoNotCount() {
        let observation = seen(
            idle(mouse: 0.5),
            frontmost: paseo,
            pointer: [click(insideTarget, ago: 3.5), click(onPaseoOverTarget, ago: 0.5)]
        )
        XCTAssertNil(decide(observation))
    }

    func testWindowsAreReadOnlyWhenARecentPointerInputNeedsThem() {
        var reads = 0
        let windows: () -> [UserActivity.ScreenWindow] = {
            reads += 1
            return []
        }
        _ = decide(seen(idle(key: 1.0), frontmost: editor, windows: windows))
        _ = decide(seen(idle(mouse: 5.0), frontmost: editor, pointer: [click(insideTarget, ago: 5.0)], windows: windows))
        XCTAssertEqual(reads, 0)
        _ = decide(seen(idle(mouse: 1.0), frontmost: editor, pointer: [click(insideTarget, ago: 1.0)], windows: windows))
        XCTAssertEqual(reads, 1)
    }

    // MARK: Windows at the time of the input

    func testTheWindowsAtTheTimeOfTheClickDecideNotTheWindowsNow() {
        // The click landed on the target; Paseo has since moved over that place.
        let atClick = [targetWindow]
        let clickOnTarget = UserActivity.PointerInput(uptime: now - 0.5, location: insideTarget, windows: atClick)
        let paseoNow = [UserActivity.ScreenWindow(pid: paseo, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertEqual(
            decide(seen(idle(mouse: 0.5), frontmost: paseo, pointer: [clickOnTarget], windows: { paseoNow })),
            .pointerWindow
        )
        // The click landed on Paseo over the target; Paseo has since closed.
        let paseoAtClick = [UserActivity.ScreenWindow(pid: paseo, bounds: CGRect(x: 500, y: 0, width: 600, height: 600)), targetWindow]
        let clickOnPaseo = UserActivity.PointerInput(uptime: now - 0.5, location: onPaseoOverTarget, windows: paseoAtClick)
        XCTAssertNil(decide(seen(idle(mouse: 0.5), frontmost: paseo, pointer: [clickOnPaseo], windows: { [self.targetWindow] })))
    }

    func testTheWindowsNowAreReadOnlyForARecordWithoutItsOwn() {
        var reads = 0
        let windows: () -> [UserActivity.ScreenWindow] = {
            reads += 1
            return self.screen
        }
        let withWindows = UserActivity.PointerInput(uptime: now - 0.5, location: insideEditor, windows: [])
        _ = decide(seen(idle(mouse: 0.5), frontmost: editor, pointer: [withWindows], windows: windows))
        XCTAssertEqual(reads, 0)
        _ = decide(seen(idle(mouse: 0.5), frontmost: editor, pointer: [click(insideEditor, ago: 0.6), click(insideEditor, ago: 0.5)], windows: windows))
        XCTAssertEqual(reads, 1, "read once for both records")
    }

    // MARK: Unknown location

    func testAClickOnASystemWindowFallsBackToTheFrontmostApp() {
        // The menu bar strip belongs to the window server; its clicks go to
        // the frontmost app's menus.
        let menuBar = UserActivity.ScreenWindow(pid: 1, bounds: CGRect(x: 0, y: 0, width: 2000, height: 24), isApp: false)
        let windows = [menuBar] + screen
        let onMenuBar = CGPoint(x: 50, y: 10)
        let targetInFront = seen(idle(mouse: 0.5), frontmost: target, pointer: [click(onMenuBar, ago: 0.5)], windows: { windows })
        XCTAssertEqual(decide(targetInFront), .pointerFrontmost)
        let paseoInFront = seen(idle(mouse: 0.5), frontmost: paseo, pointer: [click(onMenuBar, ago: 0.5)], windows: { windows })
        XCTAssertNil(decide(paseoInFront))
    }

    func testUnknownLocationFallsBackToTheFrontmostApp() {
        // No tap: the log has nothing.
        XCTAssertEqual(decide(seen(idle(mouse: 1.0), frontmost: target, logSince: nil)), .pointerFrontmost)
        XCTAssertNil(decide(seen(idle(mouse: 1.0), frontmost: paseo, logSince: nil)))
    }

    func testALogThatStartedInsideTheWindowFallsBack() {
        let observation = seen(
            idle(mouse: 0.5),
            frontmost: target,
            pointer: [click(insideEditor, ago: 0.5)],
            logSince: now - 1.0
        )
        XCTAssertEqual(decide(observation), .pointerFrontmost)
    }

    func testAClickFromBeforeControlWasTakenCountsOnlyForTheFrontmostApp() {
        // The log starts when the agent takes control, 1 s ago, so a click on
        // the background target 2 s ago has no record.
        let background = seen(idle(mouse: 2.0), frontmost: paseo, logSince: now - 1.0)
        XCTAssertNil(decide(background))
        let front = seen(idle(mouse: 2.0), frontmost: target, logSince: now - 1.0)
        XCTAssertEqual(decide(front), .pointerFrontmost)
    }

    func testAKeyFromBeforeTheLogStartedCountsOnlyForTheFrontmostApp() {
        // The log has no activation from before it started.
        let unknownHistory: (Double) -> pid_t? = { _ in nil }
        let background = UserActivity.Observation(
            now: now, idle: idle(key: 1.0), frontmost: paseo, frontmostAt: unknownHistory
        )
        XCTAssertNil(decide(background))
        let front = UserActivity.Observation(
            now: now, idle: idle(key: 1.0), frontmost: target, frontmostAt: unknownHistory
        )
        XCTAssertEqual(decide(front), .keyFrontmost)
    }

    func testALogThatMissedTheLatestInputFallsBack() {
        // The clock saw a click 0.2 s ago; the log's newest record is 1 s old.
        let observation = seen(idle(mouse: 0.2), frontmost: target, pointer: [click(insideEditor, ago: 1.0)])
        XCTAssertEqual(decide(observation), .pointerFrontmost)
        // A record a moment younger than the clock's event is the same event.
        let late = seen(idle(mouse: 0.2), frontmost: target, pointer: [click(insideEditor, ago: 0.1)])
        XCTAssertNil(decide(late))
    }

    // MARK: Plugin events

    func testEventsThePluginPostsNeverCount() throws {
        // The plugin's events come from a private source, so only states
        // other than the hardware one can have seen them a moment ago.
        final class Queries { var states: [CGEventSourceStateID] = [] }
        let queries = Queries()
        let clock: (CGEventSourceStateID, CGEventType) -> Double = { state, _ in
            queries.states.append(state)
            return state == .hidSystemState ? .infinity : 0.01
        }
        let read = UserActivity.idle(clock: clock)
        XCTAssertEqual(read, idle())
        XCTAssertFalse(queries.states.isEmpty)
        XCTAssertTrue(queries.states.allSatisfy { $0 == .hidSystemState })
        XCTAssertNil(decide(seen(read, frontmost: target)))

        // The input log keeps no event the plugin or another process posted.
        XCTAssertFalse(UserInputLog.shouldRecord(type: .leftMouseDown, sourcePid: 0, userData: kPaseoSyntheticEventUserData))
        XCTAssertFalse(UserInputLog.shouldRecord(type: .scrollWheel, sourcePid: 4242, userData: 0))
        XCTAssertTrue(UserInputLog.shouldRecord(type: .leftMouseDown, sourcePid: 0, userData: 0))
    }

    func testIdleReadsKeyMouseDownAndScrollClocks() {
        let clock: (CGEventSourceStateID, CGEventType) -> Double = { _, type in
            switch type {
            case .keyDown: return 4.0
            case .rightMouseDown: return 2.0
            case .leftMouseDown: return 3.0
            case .scrollWheel: return 1.5
            case .mouseMoved, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyUp: return 0.01
            default: return .infinity
            }
        }
        XCTAssertEqual(UserActivity.idle(clock: clock), idle(key: 4.0, mouse: 2.0, scroll: 1.5))
    }

    // MARK: check

    private func check(_ command: String, target: pid_t?, _ observation: UserActivity.Observation) throws {
        try UserActivity.check(command: command, target: target, observe: { observation }, appName: { _ in "TextEdit" })
    }

    func testPauseWindowIsThreeSeconds() {
        XCTAssertEqual(UserActivity.pauseSeconds, 3.0)
    }

    func testRefusalNamesTheTargetAndKeepsTheIdleTimesForTheAuditOnly() {
        for command in UserActivity.gatedCommands {
            XCTAssertThrowsError(try check(command, target: target, seen(idle(key: 1.25, mouse: 7.5), frontmost: target))) { error in
                guard let error = error as? HelperError else { return XCTFail("not a HelperError: \(error)") }
                XCTAssertEqual(error.code, HelperError.userActive)
                XCTAssertEqual(
                    error.message,
                    "The user is using TextEdit. Wait a few seconds, call get_app_state again, then retry."
                )
                XCTAssertEqual(
                    error.userActivityDetail,
                    "user_active: rule=key_frontmost key_down_idle=1.250s mouse_down_idle=7.500s scroll_idle=infs pause=3.000s"
                )
                XCTAssertNil(error.message.rangeOfCharacter(from: .decimalDigits))
            }
        }
        XCTAssertEqual(UserActivity.gatedCommands.count, 9)
    }

    func testAllowedActionsDoNotThrow() {
        XCTAssertNoThrow(try check("type_text", target: target, seen(idle(key: 0.5), frontmost: editor)))
        XCTAssertNoThrow(try check("click", target: target, seen(idle(key: 4.0), frontmost: target)))
    }

    func testNothingIsReadForReadCommandsOrAnUnknownTarget() throws {
        var reads = 0
        let observe: () -> UserActivity.Observation = {
            reads += 1
            return self.seen(self.idle(key: 0), frontmost: self.target)
        }
        for command in ["status", "list_apps", "list_windows", "get_app_state", "capture.signature"] {
            XCTAssertFalse(UserActivity.gatedCommands.contains(command), command)
            try UserActivity.check(command: command, target: target, observe: observe, appName: { _ in "X" })
        }
        try UserActivity.check(command: "click", target: nil, observe: observe, appName: { _ in "X" })
        XCTAssertEqual(reads, 0)
    }

    // MARK: Windows

    func testTheFrontmostWindowAtThePointDecides() {
        XCTAssertEqual(UserActivity.window(at: insideTarget, in: screen)?.pid, target)
        XCTAssertEqual(UserActivity.window(at: onPaseoOverTarget, in: screen)?.pid, paseo)
        XCTAssertNil(UserActivity.window(at: CGPoint(x: 900, y: 650), in: screen))
    }

    func testScreenWindowsLeaveOutTheHelperAndClearWindows() {
        func info(_ pid: pid_t, alpha: Double = 1, _ rect: CGRect) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: pid,
                kCGWindowAlpha as String: alpha,
                kCGWindowBounds as String: rect.dictionaryRepresentation,
            ]
        }
        let full = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let windows = UserActivity.screenWindows([
            info(1, full),             // the helper's overlay
            info(2, alpha: 0, full),   // a clear window
            info(3, CGRect(x: 0, y: 0, width: 0, height: 0)),
            info(4, CGRect(x: 0, y: 0, width: 1000, height: 24)),  // a system process
            info(target, full),
        ], ownPid: 1, isApp: { $0 != 4 })
        XCTAssertEqual(windows, [
            .init(pid: 4, bounds: CGRect(x: 0, y: 0, width: 1000, height: 24), isApp: false),
            .init(pid: target, bounds: full),
        ])
    }
}
