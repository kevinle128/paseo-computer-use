import CoreGraphics
import XCTest
@testable import PaseoComputerUseCore

/// Drives a `FocusWatch` with a fake clock, a fake front process, a fake
/// holder of the keyboard, and fake correction steps (`FakeDesktop`). Nothing
/// here activates an app or reads real input state.
private final class Rig {
    let editor = FrontmostGuard.App(pid: 10, label: "com.example.editor")
    let browser = FrontmostGuard.App(pid: 20, label: "com.example.browser")
    let stranger = FrontmostGuard.App(pid: 30, label: "com.example.stranger")
    let desktop = FakeDesktop()
    var time: Double {
        get { desktop.time }
        set { desktop.time = newValue }
    }
    var front: FrontmostGuard.App? {
        get { desktop.front }
        set { desktop.front = newValue }
    }
    /// Seconds since the last hardware event of each type; a type not listed
    /// was last seen long ago.
    var idle: [CGEventType: Double] = [:]
    /// Whether Command, Control, or Option is held at each poll.
    var switchModifierHeld = false
    var launchedPids: Set<pid_t> = []
    /// Requests for the public activation.
    var activations: [FrontmostGuard.App] { desktop.activations }
    var activateResult: Bool {
        get { desktop.activateResult }
        set { desktop.activateResult = newValue }
    }
    /// Whether the previous app is in front after an activation is requested.
    var activationTakesEffect: Bool {
        get { desktop.activationTakesEffect }
        set { desktop.activationTakesEffect = newValue }
    }
    var results: [FocusWatch.Result?] = []
    private(set) var watch: FocusWatch!

    /// The action is aimed at the browser unless a test says otherwise. With
    /// no `keyFocusAtStart` the user's window is not known, so a correction
    /// uses the public activation, and the keyboard is not watched.
    init(
        actionStart: Double = 99.0,
        targetPid: pid_t? = 20,
        switchModifierAtStart: Bool = false,
        keyDownRule: FocusWatch.KeyDownRule = FocusWatch.keyDownRule,
        keyboardAction: Bool = false,
        keyFocusAtStart: KeyFocus.AtStart = .unknown,
        configure: (FakeDesktop) -> Void = { _ in }
    ) {
        desktop.apps = [10: editor, 20: browser, 30: stranger]
        desktop.front = editor
        desktop.keyHolder = editor
        // The user's window reads the same as at the action start unless a
        // test changes it.
        desktop.userWindowId = keyFocusAtStart.windowId
        configure(desktop)
        watch = FocusWatch(
            previous: editor,
            targetPid: targetPid,
            actionStart: actionStart,
            now: { self.time },
            read: { self.front },
            confirmFront: { self.desktop.readAppKitFront() },
            idleSeconds: { self.idle[$0] ?? 1000 },
            switchModifierAtStart: switchModifierAtStart,
            switchModifierHeld: { self.switchModifierHeld },
            keyDownRule: keyDownRule,
            launchedByAction: { self.launchedPids.contains($0) },
            keyboardAction: keyboardAction,
            keyFocusAtStart: keyFocusAtStart,
            readKeyHolder: { self.desktop.readKeyHolder() },
            correction: desktop.correction(),
            onFinish: { self.results.append($0) }
        )
    }

    func advance(_ seconds: Double) {
        time += seconds
        watch.tick()
    }

    /// The browser takes focus and the watch gets as far as asking for the restore.
    func requestRestore() {
        front = browser
        advance(0.05)
        advance(0.05)
    }
}

final class FocusWatchTests: XCTestCase {
    func testNothingHappensWhileTheSameAppStaysInFront() {
        let rig = Rig()
        for _ in 0..<50 { rig.advance(0.05) }
        XCTAssertTrue(rig.watch.isFinished)
        XCTAssertEqual(rig.results.count, 1)
        XCTAssertNil(rig.results[0])
        XCTAssertTrue(rig.activations.isEmpty)
    }

    func testTheAppTheActionWasAimedAtTakingFocusLateIsReplacedByThePreviousApp() {
        let rig = Rig()
        rig.advance(0.5)
        rig.front = rig.browser
        rig.advance(0.4)
        XCTAssertTrue(rig.activations.isEmpty, "the app is seen once before it is replaced")
        rig.advance(0.05)
        XCTAssertEqual(rig.activations, [rig.editor])
        rig.advance(0.05)
        XCTAssertEqual(
            rig.results.first??.line,
            "user_focus_changed: com.example.editor -> com.example.browser (restored after 950 ms)"
        )
        XCTAssertTrue(rig.watch.isFinished)
    }

    func testAProcessLaunchedByTheActionIsReplacedToo() {
        let rig = Rig()
        rig.launchedPids = [30]
        rig.front = rig.stranger
        rig.advance(0.05)
        rig.advance(0.05)
        XCTAssertEqual(rig.activations.map(\.pid), [10])
    }

    func testAnotherAppTakingFocusIsReportedAndLeftAlone() {
        let rig = Rig()
        rig.front = rig.stranger
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(
            rig.results.first??.line,
            "user_focus_changed: com.example.editor -> com.example.stranger (not restored: another app took focus)"
        )
    }

    func testNothingIsRestoredWhenTheActionHasNoKnownApp() {
        let rig = Rig(targetPid: nil)
        rig.front = rig.browser
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .anotherAppTookFocus)
    }

    func testOnlyThePreviousAppIsEverActivated() {
        let rig = Rig()
        rig.front = rig.browser
        for _ in 0..<4 { rig.advance(0.05) }
        XCTAssertEqual(rig.activations.map(\.pid), [10])
    }

    func testTheChangeIsKeptWhenTheUserPressedAShortcutAfterTheActionStarted() {
        let rig = Rig(actionStart: 99.0)
        rig.advance(0.2)
        rig.switchModifierHeld = true  // Command is down
        rig.idle[.keyDown] = 0.3  // a key down 0.3 s ago, after the action began
        rig.front = rig.browser
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(
            rig.results.first??.line,
            "user_focus_changed: com.example.editor -> com.example.browser (user switched apps)"
        )
    }

    func testTypingInThePreviousAppDoesNotKeepTheTargetInFront() {
        // The user types a prompt in the editor (Shift for capitals) while
        // the browser takes focus: the editor gets the front back.
        let rig = Rig(actionStart: 99.0)
        rig.idle[.keyDown] = 0.01
        rig.idle[.flagsChanged] = 0.02
        rig.requestRestore()
        XCTAssertEqual(rig.activations.map(\.pid), [10])
        rig.advance(0.05)
        XCTAssertEqual(rig.results.first??.outcome, .restored(afterMs: 100))
    }

    func testEveryKeyDownKeepsTheTargetWhenTheRuleCountsAllKeys() {
        let rig = Rig(actionStart: 99.0, keyDownRule: .any)
        rig.idle[.keyDown] = 0.01
        rig.front = rig.browser
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .userSwitched)
    }

    func testACommandTabBegunBeforeTheActionAndEndedAfterItIsNotUndone() {
        // Command was down when the action started, Tab went down before the
        // start, and the switch came with the release of Command after it.
        let rig = Rig(actionStart: 99.0, switchModifierAtStart: true)
        rig.idle[.keyDown] = 1.5  // Tab at 98.55, before the action
        rig.advance(0.2)
        rig.idle[.flagsChanged] = 0.05  // Command released at 100.15
        rig.front = rig.browser
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .userSwitched)
        XCTAssertTrue(rig.results.first??.detail?.contains("switch_modifier_seen=true") ?? false)
    }

    func testACommandReleaseSeenAtAPollCountsWithEitherRule() {
        for rule in [FocusWatch.KeyDownRule.withSwitchModifier, .any] {
            let rig = Rig(actionStart: 99.0, keyDownRule: rule)
            rig.switchModifierHeld = true
            rig.advance(0.05)
            rig.switchModifierHeld = false
            rig.idle[.flagsChanged] = 0.01
            rig.front = rig.browser
            rig.advance(0.05)
            XCTAssertEqual(rig.results.first??.outcome, .userSwitched, "rule \(rule)")
        }
    }

    func testAPlainModifierChangeWithoutCommandControlOrOptionDoesNotCount() {
        let rig = Rig(actionStart: 99.0, keyDownRule: .any)
        rig.idle[.flagsChanged] = 0.01  // Shift
        rig.requestRestore()
        XCTAssertEqual(rig.activations.map(\.pid), [10])
    }

    func testMovingScrollingAndDraggingDuringTheWatchDoNotKeepTheTargetInFront() {
        // A person reads on the Mac while the agent works: the pointer moves
        // and the page scrolls, but nothing that can switch apps happens.
        let rig = Rig(actionStart: 99.0)
        for type: CGEventType in [.mouseMoved, .scrollWheel, .leftMouseDragged, .keyUp] {
            rig.idle[type] = 0
        }
        rig.advance(0.2)
        rig.front = rig.browser
        rig.advance(0.05)
        rig.advance(0.05)
        XCTAssertEqual(rig.activations.map(\.pid), [10])
        rig.advance(0.05)
        XCTAssertEqual(rig.results.first??.outcome, .restored(afterMs: 300))
    }

    func testAMouseDownRightBeforeTheTargetCameToTheFrontKeepsIt() {
        // The editor was seen in front at 100.5; the click at 100.35 can be
        // the one on the browser's Dock icon or window.
        let rig = Rig(actionStart: 99.0)
        rig.advance(0.5)  // time 100.5
        rig.front = rig.browser
        rig.idle[.leftMouseDown] = 0.2
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .userSwitched)
    }

    func testAMouseDownTwoSecondsBeforeTheTargetCameToTheFrontDoesNotKeepIt() {
        let rig = Rig(actionStart: 99.0)
        rig.advance(0.5)  // the editor is still in front at 100.5
        rig.front = rig.browser
        rig.idle[.leftMouseDown] = 2.05  // at 98.5, 2 s before 100.5
        rig.advance(0.05)
        rig.advance(0.05)
        XCTAssertEqual(rig.activations.map(\.pid), [10])
        rig.advance(0.05)
        XCTAssertEqual(rig.results.first??.outcome, .restored(afterMs: 600))
    }

    func testADockClickWhoseMouseUpCameRightBeforeASlowTargetCameForwardKeepsIt() {
        // The Dock switches on the mouse up. The down was 0.5 s before the
        // target came forward at 100.5, the up 0.2 s before.
        let rig = Rig(actionStart: 99.0)
        rig.advance(0.5)  // time 100.5
        rig.front = rig.browser
        rig.idle[.leftMouseDown] = 0.55  // at 100.0
        rig.idle[.leftMouseUp] = 0.25  // at 100.3
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .userSwitched)
    }

    func testAMouseUpWellBeforeTheTargetCameToTheFrontDoesNotKeepIt() {
        let rig = Rig(actionStart: 99.0)
        rig.advance(0.5)
        rig.front = rig.browser
        rig.idle[.leftMouseDown] = 0.6
        rig.idle[.leftMouseUp] = 0.45  // at most 100.15, 0.35 s before 100.5
        rig.requestRestore()
        XCTAssertEqual(rig.activations.map(\.pid), [10])
    }

    func testAMouseDownAfterTheActionButWellBeforeTheTargetCameToTheFrontDoesNotKeepIt() {
        let rig = Rig(actionStart: 99.0)
        rig.advance(0.5)  // the editor is still in front at 100.5
        rig.front = rig.browser
        rig.idle[.rightMouseDown] = 0.45  // at most 100.15: after the action, 0.35 s before 100.5
        rig.requestRestore()
        XCTAssertEqual(rig.activations.map(\.pid), [10])
    }

    func testAMouseDownInTheTargetAfterItCameToTheFrontKeepsIt() {
        let rig = Rig(actionStart: 99.0)
        rig.advance(0.5)
        rig.front = rig.browser
        rig.advance(0.05)
        rig.idle[.otherMouseDown] = 0.01
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .userSwitched)
    }

    func testTheTargetAlreadyInFrontAtTheFirstLookIsJudgedFromTheActionStart() {
        // No poll saw the editor after the action started, so the target may
        // have come forward as early as the start: a click 0.2 s before the
        // start can be the one that brought it.
        let rig = Rig(actionStart: 99.9)
        rig.front = rig.browser
        rig.idle[.leftMouseDown] = 0.35  // at 99.7, 0.2 s before the start
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .userSwitched)
    }

    func testTheAuditDetailHasTheIdleTimesOfTheDecidingCheck() {
        let rig = Rig(actionStart: 99.0)
        rig.advance(0.5)
        rig.front = rig.browser
        rig.idle[.keyDown] = 100
        rig.idle[.leftMouseDown] = 2.05
        rig.requestRestore()
        rig.advance(0.05)
        XCTAssertEqual(
            rig.results.first??.detail,
            "focus_watch: restored key_down_idle=100.000s flags_changed_idle=1000.000s"
                + " mouse_down_idle=2.050s mouse_up_idle=1000.000s switch_modifier_seen=false"
                + " checked_after_action=1.600s front_from_after_action=1.500s"
                + " gate_held_ms=0 gate_over_cap=false gate_released_by=body restore_path=activate target_reasserted=true"
                + " key_focus_returned=false user_window_raised=false"
        )
        XCTAssertFalse(rig.results.first??.line?.contains("idle") ?? true, "the agent's line has no idle times")
    }

    func testAnotherAppTakingFocusHasNoAuditDetail() {
        let rig = Rig()
        rig.front = rig.stranger
        rig.advance(0.05)
        XCTAssertNil(rig.results.first??.detail)
    }

    func testInputJustBeforeTheActionStillCountsForAProcessTheActionLaunched() {
        let rig = Rig(actionStart: 99.0)
        rig.launchedPids = [30]
        rig.idle[.leftMouseDown] = 1.5  // the click was at 98.55, 0.45 s before the action
        rig.front = rig.stranger
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .userSwitched)
    }

    func testScrollingJustBeforeTheActionDoesNotCountForAProcessTheActionLaunched() {
        let rig = Rig(actionStart: 99.0)
        rig.launchedPids = [30]
        rig.idle[.scrollWheel] = 0.01
        rig.idle[.mouseMoved] = 0.01
        rig.front = rig.stranger
        rig.advance(0.05)
        rig.advance(0.05)
        XCTAssertEqual(rig.activations.map(\.pid), [10])
    }

    func testInputBeforeTheActionDoesNotKeepTheTargetInFront() {
        let rig = Rig(actionStart: 99.0)
        rig.idle[.keyDown] = 1.5  // the last key down was at 98.55, before the action started
        rig.idle[.leftMouseDown] = 1.5
        rig.requestRestore()
        XCTAssertEqual(rig.activations.map(\.pid), [10])
    }

    func testTheTargetThatTookFocusAfterCommandNWithNoHardwareInputIsRestored() {
        // The plugin's own key presses can reset the session idle clock, but
        // the watch reads only the hardware clock, which they leave alone.
        let rig = Rig(actionStart: 99.0)
        rig.idle[.keyDown] = 32
        rig.idle[.leftMouseDown] = 32
        rig.advance(0.3)
        rig.front = rig.browser
        rig.advance(0.05)
        rig.advance(0.05)
        XCTAssertEqual(rig.activations.map(\.pid), [10])
        rig.advance(0.05)
        XCTAssertEqual(
            rig.results.first??.line,
            "user_focus_changed: com.example.editor -> com.example.browser (restored after 400 ms)"
        )
    }

    func testInputLongBeforeTheActionDoesNotStopTheRestore() {
        let rig = Rig(actionStart: 99.0)
        rig.idle[.keyDown] = 30
        rig.idle[.leftMouseDown] = 30
        rig.requestRestore()
        XCTAssertEqual(rig.activations.map(\.pid), [10])
    }

    func testInputBetweenTheFirstLookAndTheRequestStopsTheRestore() {
        let rig = Rig()
        rig.front = rig.browser
        rig.advance(0.05)
        rig.idle[.leftMouseDown] = 0.01
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .userSwitched)
    }

    func testAnAppThatLeavesBeforeTheRequestIsNotReplaced() {
        let rig = Rig()
        rig.front = rig.browser
        rig.advance(0.05)
        rig.front = rig.editor
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertFalse(rig.watch.isFinished)
    }

    func testAnotherAppTakingTheFocusBeforeTheRequestIsNotReplaced() {
        let rig = Rig()
        rig.front = rig.browser
        rig.advance(0.05)
        rig.front = rig.stranger
        rig.advance(0.05)
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .anotherAppTookFocus)
    }

    func testACancelBeforeTheRequestStopsTheRestore() {
        let rig = Rig()
        rig.front = rig.browser
        rig.advance(0.05)
        rig.watch.cancel()
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertNil(rig.results.first ?? nil)
        XCTAssertTrue(rig.watch.isFinished)
    }

    func testACancelAfterTheRequestSaysTheRestoreMayStillApply() {
        let rig = Rig()
        rig.activationTakesEffect = false
        rig.requestRestore()
        rig.watch.cancel()
        rig.advance(0.05)
        XCTAssertEqual(rig.results.first??.outcome, .stoppedAfterRequest)
        XCTAssertEqual(
            rig.results.first??.line,
            "user_focus_changed: com.example.editor -> com.example.browser (stopped; the restore may still apply)"
        )
    }

    func testARestoreInFlightIsVisibleToOtherThreads() {
        let rig = Rig()
        rig.activationTakesEffect = false
        XCTAssertFalse(rig.watch.isRestoring)
        rig.requestRestore()
        XCTAssertTrue(rig.watch.isRestoring)
        rig.front = rig.editor
        rig.advance(0.05)
        XCTAssertFalse(rig.watch.isRestoring)
        XCTAssertEqual(rig.results.first??.outcome, .restored(afterMs: 100))
    }

    func testARefusedActivationIsReportedAsNotRestored() {
        let rig = Rig()
        rig.activateResult = false
        rig.requestRestore()
        XCTAssertEqual(
            rig.results.first??.line,
            "user_focus_changed: com.example.editor -> com.example.browser (could not restore)"
        )
    }

    func testAnActivationThatDoesNotTakeEffectIsReportedAsNotRestored() {
        let rig = Rig()
        rig.activationTakesEffect = false
        rig.requestRestore()
        XCTAssertNil(rig.results.first ?? nil)
        for _ in 0..<10 { rig.advance(0.05) }
        XCTAssertEqual(rig.results.count, 1)
        XCTAssertEqual(rig.results[0]?.outcome, .couldNotRestore)
        XCTAssertEqual(rig.activations.count, 1, "restore is tried once per action")
    }

    func testTheWatchEndsAfterItsWindow() {
        let rig = Rig()
        rig.advance(FocusWatch.windowSeconds + 0.01)
        XCTAssertTrue(rig.watch.isFinished)
        rig.front = rig.browser
        rig.advance(0.05)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.count, 1)
    }

    func testACancelEndsTheWatchWithoutRestoring() {
        let rig = Rig()
        rig.watch.cancel()
        rig.front = rig.browser
        rig.advance(0.05)
        XCTAssertTrue(rig.watch.isFinished)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.count, 1)
        XCTAssertNil(rig.results[0])
    }

    func testUserInputIsJudgedByEventTypeAndTime() {
        func evidence(
            keyDown: Double = 1000,
            flagsChanged: Double = 1000,
            mouseDown: Double = 1000,
            mouseUp: Double = 1000,
            modifier: Bool = false
        ) -> FocusWatch.Evidence {
            // Checked 1 s after the action; the app can be in front from 0.5 s.
            FocusWatch.Evidence(
                idle: .init(keyDown: keyDown, flagsChanged: flagsChanged, mouseDown: mouseDown, mouseUp: mouseUp),
                checkedAt: 1,
                frontFrom: 0.5,
                switchModifierSeen: modifier
            )
        }
        func target(_ e: FocusWatch.Evidence, _ rule: FocusWatch.KeyDownRule = .withSwitchModifier) -> Bool {
            FocusWatch.userActed(e, isTarget: true, keyDownRule: rule)
        }
        // The target: a key down since the start with Command, Control, or
        // Option seen, or any key down when every key counts.
        XCTAssertTrue(target(evidence(keyDown: 0.9, modifier: true)))
        XCTAssertFalse(target(evidence(keyDown: 0.9)))
        XCTAssertTrue(target(evidence(keyDown: 0.9), .any))
        XCTAssertFalse(target(evidence(keyDown: 1.1, modifier: true)))
        XCTAssertFalse(target(evidence(keyDown: 1.1), .any))
        // A modifier change since the start, only with a switch modifier seen.
        XCTAssertTrue(target(evidence(flagsChanged: 0.9, modifier: true)))
        XCTAssertTrue(target(evidence(flagsChanged: 0.9, modifier: true), .any))
        XCTAssertFalse(target(evidence(flagsChanged: 0.9), .any))
        XCTAssertFalse(target(evidence(flagsChanged: 1.1, modifier: true)))
        // The latest mouse down or up from 0.2 s.
        XCTAssertTrue(target(evidence(mouseDown: 0.7)))
        XCTAssertFalse(target(evidence(mouseDown: 0.9)))
        XCTAssertTrue(target(evidence(mouseDown: 1.2, mouseUp: 0.7)))
        XCTAssertFalse(target(evidence(mouseDown: 1.2, mouseUp: 0.9)))
        // A launched process: a key down or a mouse down or up from 1 s
        // before the start, with either rule.
        XCTAssertTrue(FocusWatch.userActed(evidence(keyDown: 1.9), isTarget: false))
        XCTAssertTrue(FocusWatch.userActed(evidence(mouseDown: 1.9), isTarget: false))
        XCTAssertTrue(FocusWatch.userActed(evidence(mouseDown: 3, mouseUp: 1.9), isTarget: false))
        XCTAssertFalse(FocusWatch.userActed(evidence(keyDown: 2.1, mouseDown: 2.1, mouseUp: 2.1), isTarget: false))
    }

    func testTheDefaultRuleCountsOnlyKeysWithCommandControlOrOption() {
        XCTAssertEqual(FocusWatch.keyDownRule, .withSwitchModifier)
    }

    func testCommandControlAndOptionAreSwitchModifiersAndShiftIsNot() {
        XCTAssertTrue(FocusWatch.hasSwitchModifier(.maskCommand))
        XCTAssertTrue(FocusWatch.hasSwitchModifier(.maskControl))
        XCTAssertTrue(FocusWatch.hasSwitchModifier(.maskAlternate))
        XCTAssertTrue(FocusWatch.hasSwitchModifier([.maskShift, .maskCommand]))
        XCTAssertFalse(FocusWatch.hasSwitchModifier(.maskShift))
        XCTAssertFalse(FocusWatch.hasSwitchModifier(.maskAlphaShift))
        XCTAssertFalse(FocusWatch.hasSwitchModifier([]))
    }

    func testOnlyTheHardwareModifierStateIsRead() {
        var asked: [CGEventSourceStateID] = []
        let held = FocusWatch.hardwareSwitchModifierHeld { state in
            asked.append(state)
            return .maskCommand
        }
        XCTAssertTrue(held)
        XCTAssertEqual(asked, [.hidSystemState])
    }

    func testOwnPostedKeysDoNotCountAsUserInput() {
        // The session clock was reset 10 ms ago by a key the plugin posted;
        // no input device was touched for 32 s.
        let idle = FocusWatch.hardwareIdleSeconds(.keyDown) { state, _ in
            state == .hidSystemState ? 32 : 0.01
        }
        XCTAssertEqual(idle, 32)
    }

    func testOnlyTheHardwareClockIsRead() {
        var asked: [CGEventSourceStateID] = []
        let idle = FocusWatch.hardwareIdleSeconds(.leftMouseDown) { state, _ in
            asked.append(state)
            return 0.2
        }
        XCTAssertEqual(idle, 0.2)
        XCTAssertEqual(asked, [.hidSystemState])
    }

    func testOnlyKeyDownModifierAndMouseButtonClocksAreRead() {
        var asked: [CGEventType] = []
        let idle = FocusWatch.InputIdle.read { type in
            asked.append(type)
            switch type {
            case .rightMouseDown: return 3
            case .otherMouseDown: return 2
            case .leftMouseDown: return 5
            case .leftMouseUp: return 4
            case .rightMouseUp: return 1.5
            case .otherMouseUp: return 6
            case .flagsChanged: return 8
            case .keyDown: return 7
            default: return 0
            }
        }
        XCTAssertEqual(idle, FocusWatch.InputIdle(keyDown: 7, flagsChanged: 8, mouseDown: 2, mouseUp: 1.5))
        let expected: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]
        XCTAssertEqual(Set(asked.map(\.rawValue)), Set(expected.map(\.rawValue)))
    }
}

/// The correction steps a watch runs, on the fake desktop.
final class FocusWatchCorrectionTests: XCTestCase {
    /// The user's window and keyboard are known at the action start.
    private let userKeys = KeyFocus.AtStart(windowId: 7, userHoldsKeys: true)
    private let correctionSteps = ["hold", "reassert 20", "window request 10 [7]", "key records 10 [7]", "release"]

    func testATargetThatComesToTheFrontIsCorrectedWhileTheScreenIsHeld() {
        let rig = Rig(keyFocusAtStart: userKeys)
        rig.advance(0.02)
        rig.front = rig.browser
        rig.advance(0.02)
        XCTAssertFalse(rig.desktop.log.contains("hold"), "the first look asks for nothing")
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.log, correctionSteps)
        XCTAssertEqual(rig.desktop.holds, 1)
        XCTAssertEqual(rig.desktop.releases, 1)
        XCTAssertTrue(rig.activations.isEmpty, "the window request brought the editor back")
        rig.advance(0.02)
        XCTAssertEqual(
            rig.results.first??.line,
            "user_focus_changed: com.example.editor -> com.example.browser (restored after 60 ms)"
        )
        let detail = rig.results.first??.detail ?? ""
        XCTAssertTrue(detail.hasSuffix(
            "gate_held_ms=0 gate_over_cap=false gate_released_by=body restore_path=front_process target_reasserted=true"
                + " key_focus_returned=true user_window_raised=false"
        ), detail)
        XCTAssertEqual(rig.desktop.log.last, "raise check 10 [7]")
    }

    func testWithoutTheHoldAndTheWindowRequestTheActivationIsUsed() {
        let rig = Rig(keyFocusAtStart: userKeys) { desktop in
            desktop.holdAvailable = false
            desktop.windowRequestAvailable = false
        }
        rig.requestRestore()
        XCTAssertEqual(rig.activations, [rig.editor])
        XCTAssertFalse(rig.desktop.log.contains("hold"))
        rig.advance(0.02)
        XCTAssertEqual(rig.results.first??.outcome, .restored(afterMs: 100))
        XCTAssertTrue(rig.results.first??.detail?.contains("gate_held_ms=none gate_over_cap=none gate_released_by=none restore_path=activate") ?? false)
    }

    func testAUserSwitchRunsNoCorrectionStep() {
        let rig = Rig(keyFocusAtStart: userKeys)
        rig.switchModifierHeld = true
        rig.idle[.keyDown] = 0.01
        rig.front = rig.browser
        rig.advance(0.02)
        XCTAssertEqual(rig.results.first??.outcome, .userSwitched)
        XCTAssertEqual(rig.desktop.log, [], "no hold, no request, no activation")
    }

    func testAWindowRequestThatDoesNotShowIsFollowedByTheActivationOnce() {
        let rig = Rig(keyFocusAtStart: userKeys) { $0.windowRequestTakesEffect = false }
        rig.requestRestore()
        XCTAssertEqual(rig.front, rig.browser)
        rig.advance(0.06)
        XCTAssertTrue(rig.activations.isEmpty, "the window request gets its grace time")
        rig.activationTakesEffect = false
        rig.advance(0.06)
        XCTAssertEqual(rig.activations, [rig.editor])
        rig.advance(0.06)
        XCTAssertEqual(rig.activations.count, 1, "the activation follows once")
        rig.front = rig.editor
        rig.advance(0.02)
        XCTAssertTrue(rig.results.first??.detail?.contains("restore_path=front_process_then_activate") ?? false)
    }

    func testNoActivationFollowsWhenNoRegularAppIsInFront() {
        let rig = Rig(keyFocusAtStart: userKeys) { $0.windowRequestTakesEffect = false }
        rig.requestRestore()
        rig.front = nil
        rig.advance(0.2)
        XCTAssertTrue(rig.activations.isEmpty, "a launcher in front is never interrupted")
    }

    func testTheUserWindowIsRaisedWhenAnotherWindowOfItsAppIsAbove() {
        let rig = Rig(keyFocusAtStart: userKeys) { $0.userWindowBuried = true }
        rig.requestRestore()
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.raised.map(\.windowId), [7])
        XCTAssertTrue(rig.results.first??.detail?.hasSuffix("user_window_raised=true") ?? false)
    }

    func testAStalledStepIsCutByTheWatchdogAndTheHoldNeverExceedsTheCap() {
        let rig = Rig(keyFocusAtStart: userKeys) { $0.windowRequestTakes = 0.4 }
        rig.requestRestore()
        XCTAssertEqual(rig.desktop.releases, 1)
        rig.advance(0.02)
        let detail = rig.results.first??.detail ?? ""
        XCTAssertTrue(detail.contains("gate_held_ms=250 gate_over_cap=false gate_released_by=watchdog"), detail)
    }

    func testAStalledCorrectionStillGetsTheWholeConfirmTime() {
        // The window request stalls past the cap and does not take effect;
        // the waits for it start when the steps end, so the activation still
        // follows and the restore is confirmed.
        let rig = Rig(keyFocusAtStart: userKeys) { desktop in
            desktop.windowRequestTakes = 0.4
            desktop.windowRequestTakesEffect = false
        }
        rig.requestRestore()
        rig.advance(0.02)
        XCTAssertTrue(rig.activations.isEmpty, "the window request gets its grace time after the steps end")
        XCTAssertNil(rig.results.first ?? nil)
        rig.advance(0.1)
        XCTAssertEqual(rig.activations, [rig.editor])
        rig.advance(0.02)
        XCTAssertEqual(rig.results.first??.outcome, .restored(afterMs: 100))
        XCTAssertTrue(rig.results.first??.detail?.contains("restore_path=front_process_then_activate") ?? false)
    }

    func testKeysTakenByTheTargetWhileTheUserAppStaysInFrontAreGivenBack() {
        let rig = Rig(keyFocusAtStart: userKeys)
        rig.advance(0.1)
        rig.desktop.keyHolder = rig.browser
        rig.advance(0.15)
        XCTAssertTrue(rig.desktop.log.isEmpty, "the first look asks for nothing")
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.log, ["key records 10 [7]"])
        rig.advance(0.02)
        XCTAssertEqual(rig.results.first??.outcome, .keyFocusReturned(afterMs: 270))
        XCTAssertEqual(
            rig.results.first??.line,
            "user_focus_changed: key focus com.example.editor -> com.example.browser (returned after 270 ms)"
        )
        XCTAssertTrue(rig.results.first??.detail?.contains("restore_path=key_records target_reasserted=false key_focus_returned=true") ?? false)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.desktop.holds, 0, "no screen hold for the keyboard")
        XCTAssertTrue(rig.watch.isFinished)
        XCTAssertEqual(rig.results.first??.frontAfter, rig.editor)
    }

    func testOnlyOneCorrectionRunsPerAction() {
        let rig = Rig(keyFocusAtStart: userKeys)
        rig.desktop.keyHolder = rig.browser
        rig.advance(0.02)
        rig.advance(0.02)
        rig.advance(0.02)
        XCTAssertTrue(rig.watch.isFinished)
        rig.desktop.keyHolder = rig.browser
        rig.front = rig.browser
        for _ in 0..<5 { rig.advance(0.02) }
        XCTAssertEqual(rig.desktop.keyRecords.count, 1)
        XCTAssertTrue(rig.desktop.windowRequests.isEmpty)
        XCTAssertEqual(rig.results.count, 1)
    }

    func testKeysAreNotWatchedWhenTheUserAppDidNotHoldThemAtTheStart() {
        let rig = Rig(keyFocusAtStart: KeyFocus.AtStart(windowId: 7, userHoldsKeys: false))
        rig.desktop.keyHolder = rig.browser
        for _ in 0..<120 { rig.advance(0.02) }
        XCTAssertTrue(rig.watch.isFinished)
        XCTAssertNil(rig.results.first ?? nil)
        XCTAssertTrue(rig.desktop.log.isEmpty)
    }

    func testAClickThatGaveTheTargetTheKeysKeepsThemThere() {
        let rig = Rig(keyFocusAtStart: userKeys)
        rig.advance(0.1)
        rig.idle[.leftMouseDown] = 0.01
        rig.desktop.keyHolder = rig.browser
        rig.advance(0.15)
        XCTAssertEqual(rig.results.first??.outcome, .userMovedKeyFocus)
        XCTAssertEqual(
            rig.results.first??.line,
            "user_focus_changed: key focus com.example.editor -> com.example.browser (user moved the keyboard focus)"
        )
        XCTAssertTrue(rig.desktop.log.isEmpty)
    }

    func testKeysTakenByAnotherProcessAreLeftAlone() {
        let rig = Rig(keyFocusAtStart: userKeys)
        rig.desktop.keyHolder = rig.stranger
        for _ in 0..<10 { rig.advance(0.02) }
        XCTAssertFalse(rig.watch.isFinished)
        XCTAssertTrue(rig.desktop.log.isEmpty)
    }

    func testKeysThatCannotBeAskedBackAreReported() {
        let rig = Rig(keyFocusAtStart: userKeys) { $0.keyRecordsAvailable = false }
        rig.desktop.keyHolder = rig.browser
        rig.advance(0.02)
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.log, ["key records 10 [7]"])
        XCTAssertEqual(rig.results.first??.outcome, .couldNotReturnKeyFocus)
        XCTAssertTrue(rig.results.first??.line?.hasSuffix("(could not return)") ?? false)
    }

    func testKeysThatDoNotComeBackWhileTheUserAppIsInFrontGetNoFrontRequest() {
        let rig = Rig(keyFocusAtStart: userKeys) { $0.keyRecordsTakeEffect = false }
        rig.desktop.menuOpenInPid = 10
        rig.desktop.keyHolder = rig.browser
        for _ in 0..<30 { rig.advance(0.02) }
        XCTAssertEqual(rig.desktop.log, ["key records 10 [7]"])
        XCTAssertEqual(rig.results.first??.outcome, .couldNotReturnKeyFocus)
        XCTAssertTrue(rig.desktop.menuIsOpen, "the user's open menu is not touched")
    }

    func testTheFrontRequestFollowsOnlyWhenTheKeysStayAndTheTargetTookTheFront() {
        let rig = Rig(keyFocusAtStart: userKeys) { $0.keyRecordsTakeEffect = false }
        rig.desktop.keyHolder = rig.browser
        rig.advance(0.02)
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.log, ["key records 10 [7]"])
        rig.advance(0.06)
        XCTAssertTrue(rig.desktop.windowRequests.isEmpty, "the re-check comes first")
        // The target takes the front from the user's app as well.
        rig.front = rig.browser
        rig.advance(0.06)
        XCTAssertEqual(rig.desktop.windowRequests.map(\.pid), [10])
        rig.desktop.keyRecordsTakeEffect = true
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.windowRequests.count, 1, "the request follows once")
        XCTAssertTrue(rig.activations.isEmpty)
    }

    func testNoFrontRequestFollowsWhenAThirdAppIsInFront() {
        let rig = Rig(keyFocusAtStart: userKeys) { $0.keyRecordsTakeEffect = false }
        rig.desktop.keyHolder = rig.browser
        rig.advance(0.02)
        rig.advance(0.02)
        rig.front = rig.stranger
        for _ in 0..<20 { rig.advance(0.02) }
        XCTAssertTrue(rig.desktop.windowRequests.isEmpty)
        XCTAssertTrue(rig.activations.isEmpty)
        XCTAssertEqual(rig.results.first??.outcome, .couldNotReturnKeyFocus)
    }

    func testAPlainKeyIntoABackgroundTargetGivesNoKeysBack() {
        // The plugin's own key window records move the system-wide focused
        // app to the target while the user's app stays in front.
        let rig = Rig(keyboardAction: true, keyFocusAtStart: userKeys)
        rig.desktop.menuOpenInPid = 10
        rig.desktop.keyHolder = rig.browser
        for _ in 0..<120 { rig.advance(0.02) }
        XCTAssertTrue(rig.watch.isFinished)
        XCTAssertNil(rig.results.first ?? nil, "no key_focus_returned and no line")
        XCTAssertEqual(rig.desktop.log, [], "no hold, no records, no request")
        XCTAssertTrue(rig.desktop.menuIsOpen)
    }

    func testAKeyboardActionGivesKeysBackOnlyWhenAppKitSaysTheUserAppLostTheFront() {
        let rig = Rig(keyboardAction: true, keyFocusAtStart: userKeys) { $0.appKitFollows = false }
        rig.desktop.appKitFront = rig.browser
        rig.desktop.keyHolder = rig.browser
        rig.advance(0.02)
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.keyRecords.map(\.pid), [10])
    }

    func testAKeyboardActionLeavesKeysHeldByALaunchedProcess() {
        let rig = Rig(keyboardAction: true, keyFocusAtStart: userKeys) { $0.appKitFollows = false }
        rig.launchedPids = [30]
        rig.desktop.appKitFront = rig.stranger
        rig.desktop.keyHolder = rig.stranger
        for _ in 0..<20 { rig.advance(0.02) }
        XCTAssertTrue(rig.desktop.log.isEmpty)
    }

    func testNoKeysAreGivenBackWhileNoRegularAppIsInFront() {
        // A launcher such as Alfred is in front: neither reader has a
        // regular app, so the user's app is unknown.
        let rig = Rig(keyFocusAtStart: userKeys)
        rig.front = nil
        rig.desktop.keyHolder = rig.browser
        for _ in 0..<120 { rig.advance(0.02) }
        XCTAssertTrue(rig.watch.isFinished)
        XCTAssertNil(rig.results.first ?? nil, "no line")
        XCTAssertEqual(rig.desktop.log, [], "no records, no request")
    }

    func testAKeyboardActionGivesNoKeysBackWhileAppKitHasNoRegularAppInFront() {
        let rig = Rig(keyboardAction: true, keyFocusAtStart: userKeys) { $0.appKitFollows = false }
        rig.desktop.appKitFront = nil
        rig.desktop.keyHolder = rig.browser
        for _ in 0..<120 { rig.advance(0.02) }
        XCTAssertNil(rig.results.first ?? nil)
        XCTAssertEqual(rig.desktop.log, [])
    }

    func testTheKeyboardIsReadLessOftenThanTheFront() {
        let rig = Rig(keyFocusAtStart: userKeys)
        // Ten polls 20 ms apart: the front is read on each, the keyboard
        // about every 100 ms.
        for _ in 0..<10 { rig.advance(0.02) }
        XCTAssertGreaterThanOrEqual(rig.desktop.keyHolderReads, 2)
        XCTAssertLessThanOrEqual(rig.desktop.keyHolderReads, 3)
    }
}

final class FrontmostGuardWatchTests: XCTestCase {
    private let editor = FrontmostGuard.App(pid: 10, label: "com.example.editor")
    private let browser = FrontmostGuard.App(pid: 20, label: "com.example.browser")

    /// A guard whose watches are built from fakes and ticked by hand.
    private final class Harness {
        var watches: [FocusWatch] = []
        var requests: [FrontmostGuard.WatchRequest] = []
        let desktop = FakeDesktop()
        var time: Double {
            get { desktop.time }
            set { desktop.time = newValue }
        }
        var front: FrontmostGuard.App? {
            get { desktop.front }
            set { desktop.front = newValue }
        }
        var activations: [FrontmostGuard.App] { desktop.activations }
        var activationTakesEffect: Bool {
            get { desktop.activationTakesEffect }
            set { desktop.activationTakesEffect = newValue }
        }
        /// What the guard reads about the user's keyboard before each action.
        var keyFocusAtStart = KeyFocus.AtStart.unknown
        var keyFocusReads = 0
        lazy var guardian = FrontmostGuard(
            startWatch: { request, finish in
                self.requests.append(request)
                let watch = FocusWatch(
                    previous: request.previous,
                    targetPid: request.targetPid,
                    actionStart: request.actionStart,
                    now: { self.time },
                    read: { self.front },
                    confirmFront: { self.desktop.readAppKitFront() },
                    idleSeconds: { _ in 1000 },
                    keyboardAction: request.isKeyboardAction,
                    keyFocusAtStart: request.keyFocus,
                    readKeyHolder: { self.desktop.readKeyHolder() },
                    correction: self.desktop.correction(),
                    onFinish: finish
                )
                self.watches.append(watch)
                return watch
            },
            readKeyFocus: { _ in
                self.keyFocusReads += 1
                self.desktop.userWindowId = self.keyFocusAtStart.windowId
                return self.keyFocusAtStart
            }
        )

        init() {
            desktop.apps = [10: FrontmostGuard.App(pid: 10, label: "com.example.editor"), 20: FrontmostGuard.App(pid: 20, label: "com.example.browser")]
        }

        func tick(_ seconds: Double = 0.05) {
            time += seconds
            watches.last?.tick()
        }
    }

    private func act(
        _ rig: Harness,
        caller: String? = nil,
        read: (() -> FrontmostGuard.App?)? = nil,
        _ action: () throws -> [String: Any] = { [:] }
    ) throws -> [String: Any] {
        try rig.guardian.run(caller: caller, target: { 20 }, read: read ?? { self.editor }, settle: {}, action)
    }

    /// The browser takes focus after the action and the watch restores the editor.
    private func restoreOnce(_ rig: Harness, caller: String? = nil) throws {
        rig.front = editor
        _ = try act(rig, caller: caller)
        rig.front = browser
        rig.tick(0.9)
        rig.tick()
        rig.tick()
        XCTAssertEqual(rig.activations.last, editor)
    }

    func testTheModifierStateAtTheActionStartGoesToTheWatch() throws {
        let rig = Harness()
        _ = try rig.guardian.run(target: { 20 }, read: { self.editor }, switchModifierHeld: { true }, settle: {}) { [:] }
        _ = try rig.guardian.run(target: { 20 }, read: { self.editor }, switchModifierHeld: { false }, settle: {}) { [:] }
        XCTAssertEqual(rig.requests.map(\.switchModifierAtStart), [true, false])
    }

    func testTheRestoreIsReportedInTheNextActionsResultOnce() throws {
        let rig = Harness()
        try restoreOnce(rig)
        let next = try act(rig)
        XCTAssertEqual(
            next[FrontmostGuard.resultKey] as? String,
            "user_focus_changed: com.example.editor -> com.example.browser (restored after 950 ms)"
        )
        XCTAssertNil(try act(rig)[FrontmostGuard.resultKey])
    }

    func testTheIdleTimesOfARestoreGoUnderTheirOwnKeyAndNotInTheLine() throws {
        let rig = Harness()
        try restoreOnce(rig)
        let next = try act(rig)
        let line = try XCTUnwrap(next[FrontmostGuard.resultKey] as? String)
        let detail = try XCTUnwrap(next[FrontmostGuard.detailKey] as? String)
        XCTAssertFalse(line.contains("idle"))
        XCTAssertTrue(detail.hasPrefix("focus_watch: restored key_down_idle=1000.000s flags_changed_idle=1000.000s mouse_down_idle=1000.000s"))
        XCTAssertNil(try act(rig)[FrontmostGuard.detailKey], "the detail is given once")
    }

    func testAFailedActionCarriesTheIdleTimesInItsError() throws {
        struct Boom: Error {}
        let rig = Harness()
        try restoreOnce(rig)
        XCTAssertThrowsError(try act(rig) { throw Boom() }) { error in
            let helperError = error as? HelperError
            XCTAssertTrue(helperError?.userFocusChanged?.contains("(restored after") == true)
            XCTAssertTrue(helperError?.focusWatchDetail?.hasPrefix("focus_watch: restored ") == true)
        }
    }

    func testARestoreThatCompletesInsideTheSettleWaitIsReportedByThatAction() throws {
        let rig = Harness()
        rig.front = editor
        let result = try rig.guardian.run(
            caller: "agent-a",
            target: { 20 },
            read: { rig.front },
            settle: {
                // The browser takes focus during the wait; the watch sees it,
                // asks for the editor, and sees the editor return.
                rig.front = self.browser
                rig.tick(0.05)
                rig.tick()
                rig.tick()
            }
        ) { [:] }
        XCTAssertEqual(rig.activations.last, editor)
        XCTAssertEqual(
            result[FrontmostGuard.resultKey] as? String,
            "user_focus_changed: com.example.editor -> com.example.browser (restored after 100 ms)"
        )
        XCTAssertNil(try act(rig, caller: "agent-a")[FrontmostGuard.resultKey], "the line is shown once")
    }

    func testARestoreThatCompletesAfterTheSettleWaitIsKeptForTheNextAction() throws {
        let rig = Harness()
        rig.front = editor
        let first = try rig.guardian.run(caller: "agent-a", target: { 20 }, read: { rig.front }, settle: {}) { [:] }
        XCTAssertNil(first[FrontmostGuard.resultKey])
        rig.front = browser
        rig.tick(0.9)
        rig.tick()
        rig.tick()
        let next = try act(rig, caller: "agent-a")
        XCTAssertTrue((next[FrontmostGuard.resultKey] as? String)?.contains("(restored after") == true)
    }

    func testTheRestoreLineGoesOnlyToTheCallerWhoseActionCausedIt() throws {
        let rig = Harness()
        try restoreOnce(rig, caller: "agent-a")
        XCTAssertNil(try act(rig, caller: "agent-b")[FrontmostGuard.resultKey])
        let own = try act(rig, caller: "agent-a")
        XCTAssertTrue((own[FrontmostGuard.resultKey] as? String)?.contains("(restored after") == true)
    }

    func testTheWatchIsToldTheAppTheActionWasAimedAt() throws {
        let rig = Harness()
        rig.front = editor
        _ = try act(rig)
        XCTAssertEqual(rig.requests.first?.targetPid, 20)
        XCTAssertEqual(rig.requests.first?.previous, editor)
    }

    func testTheNextActionEndsThePreviousWatchBeforeItReads() throws {
        let rig = Harness()
        rig.front = editor
        _ = try act(rig)
        let first = try XCTUnwrap(rig.watches.first)
        rig.front = browser
        _ = try act(rig)
        XCTAssertTrue(first.isFinished)
        XCTAssertTrue(rig.activations.isEmpty, "a cancelled watch never restores")
        XCTAssertEqual(rig.watches.count, 2, "each action has its own watch")
    }

    func testTheNextActionWaitsForARestoreThatIsInFlight() throws {
        let rig = Harness()
        rig.activationTakesEffect = false
        try restoreOnce(rig)
        let first = try XCTUnwrap(rig.watches.first)
        XCTAssertTrue(first.isRestoring)
        // The editor comes back a moment after the next action begins.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            rig.front = self.editor
            rig.time += 0.05
            first.tick()
        }
        let next = try act(rig, read: { rig.front })
        XCTAssertTrue(first.isFinished)
        XCTAssertEqual(rig.watches.count, 2)
        XCTAssertEqual(rig.requests.last?.previous, editor, "the new watch starts from the restored app")
        XCTAssertTrue((next[FrontmostGuard.resultKey] as? String)?.contains("(restored after") == true)
    }

    func testAStopEndsTheWatch() throws {
        let rig = Harness()
        rig.front = editor
        _ = try act(rig)
        rig.guardian.stopWatches()
        rig.front = browser
        rig.tick()
        XCTAssertTrue(rig.watches[0].isFinished)
        XCTAssertTrue(rig.activations.isEmpty)
    }

    func testAnActionThatWasStoppedWhileItRanStartsNoWatch() throws {
        let rig = Harness()
        _ = try act(rig) {
            rig.guardian.stopWatches()
            return [:]
        }
        XCTAssertTrue(rig.watches.isEmpty)
    }

    func testAFailedActionThatWasStoppedStartsNoWatch() {
        struct Boom: Error {}
        let rig = Harness()
        XCTAssertThrowsError(try act(rig) {
            rig.guardian.stopWatches()
            throw Boom()
        })
        XCTAssertTrue(rig.watches.isEmpty)
    }

    func testACancelledCommandStartsNoWatch() throws {
        let rig = Harness()
        let token = CommandCancellation()
        _ = try CommandCancellation.run(with: token) {
            try act(rig) {
                token.cancel()
                return [:]
            }
        }
        XCTAssertTrue(rig.watches.isEmpty)
    }

    func testAStopBeforeTheActionDoesNotBlockItsWatch() throws {
        let rig = Harness()
        rig.guardian.stopWatches()
        _ = try act(rig)
        XCTAssertEqual(rig.watches.count, 1)
    }

    func testAGuardWithoutAWatchStartsNone() throws {
        let result = try FrontmostGuard().run(read: { self.editor }, settle: {}) { ["ok": true] }
        XCTAssertEqual(result["ok"] as? Bool, true)
    }

    func testNoRegularAppInFrontBeforeTheActionStartsNoWatchAndPrintsNoLine() throws {
        let rig = Harness()
        var reads: [FrontmostGuard.App?] = [nil, browser, browser]
        let result = try act(rig, read: { reads.removeFirst() })
        XCTAssertTrue(rig.requests.isEmpty, "no watch, so no correction")
        XCTAssertEqual(rig.keyFocusReads, 0)
        XCTAssertNil(result[FrontmostGuard.resultKey])
        XCTAssertEqual(result[FrontmostGuard.detailKey] as? String, "front_app_unknown: none -> com.example.browser")
    }

    func testTheKeyboardActionFlagGoesToTheWatch() throws {
        let rig = Harness()
        _ = try rig.guardian.run(target: { 20 }, keyboard: true, read: { self.editor }, settle: {}) { [:] }
        _ = try act(rig)
        XCTAssertEqual(rig.requests.map(\.isKeyboardAction), [true, false])
    }

    func testTheUserKeyboardIsReadBeforeEachActionAndGoesToTheWatch() throws {
        let rig = Harness()
        rig.keyFocusAtStart = KeyFocus.AtStart(windowId: 7, userHoldsKeys: true)
        rig.front = editor
        _ = try act(rig)
        _ = try act(rig)
        XCTAssertEqual(rig.keyFocusReads, 2)
        XCTAssertEqual(rig.requests.first?.keyFocus, KeyFocus.AtStart(windowId: 7, userHoldsKeys: true))
    }

    func testAGuardWithoutAWatchDoesNotReadTheKeyboard() throws {
        var reads = 0
        let guardian = FrontmostGuard(readKeyFocus: { _ in
            reads += 1
            return .unknown
        })
        _ = try guardian.run(read: { self.editor }, settle: {}) { [:] }
        XCTAssertEqual(reads, 0)
    }

    func testAKeyFocusReturnIsReportedOnceAndLeavesTheUserAppInFront() throws {
        let rig = Harness()
        rig.keyFocusAtStart = KeyFocus.AtStart(windowId: 7, userHoldsKeys: true)
        rig.front = editor
        rig.desktop.keyHolder = editor
        _ = try act(rig)
        rig.desktop.keyHolder = browser
        rig.tick(0.02)
        rig.tick(0.02)
        rig.tick(0.02)
        XCTAssertTrue(rig.watches[0].isFinished)
        let next = try act(rig)
        XCTAssertEqual(
            next[FrontmostGuard.resultKey] as? String,
            "user_focus_changed: key focus com.example.editor -> com.example.browser (returned after 40 ms)",
            "no line says the app in front changed since the previous action"
        )
        XCTAssertTrue((next[FrontmostGuard.detailKey] as? String)?.hasPrefix("focus_watch: key_focus_returned ") == true)
        XCTAssertNil(try act(rig)[FrontmostGuard.resultKey])
    }
}

/// The window server's front process may only start a look; AppKit's
/// frontmost app decides.
final class FocusWatchAppKitAgreementTests: XCTestCase {
    private let userKeys = KeyFocus.AtStart(windowId: 7, userHoldsKeys: true)

    func testAWindowServerFrontThatAppKitNeverConfirmsIsNotCorrected() {
        let rig = Rig(keyFocusAtStart: userKeys) { desktop in
            desktop.appKitFollows = false
        }
        rig.desktop.appKitFront = rig.editor
        rig.front = rig.browser
        for _ in 0..<120 { rig.advance(0.02) }
        XCTAssertTrue(rig.watch.isFinished)
        XCTAssertEqual(rig.results.count, 1)
        XCTAssertNil(rig.results[0], "no line")
        XCTAssertEqual(rig.desktop.log, [], "no hold, no request, no activation")
        XCTAssertEqual(rig.desktop.holds, 0)
    }

    func testTheCorrectionWaitsForAppKitToAgree() {
        let rig = Rig(keyFocusAtStart: userKeys) { desktop in
            desktop.appKitFollows = false
        }
        rig.desktop.appKitFront = rig.editor
        rig.front = rig.browser
        rig.advance(0.02)
        rig.advance(0.02)
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.log, [], "the window server alone asks for nothing")
        rig.desktop.appKitFront = rig.browser
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.log.first, "hold")
        XCTAssertEqual(rig.desktop.windowRequests.map(\.pid), [10])
    }

    func testAnotherAppSeenOnlyByTheWindowServerPrintsNoLine() {
        let rig = Rig { desktop in
            desktop.appKitFollows = false
        }
        rig.desktop.appKitFront = rig.editor
        rig.front = rig.stranger
        for _ in 0..<120 { rig.advance(0.02) }
        XCTAssertNil(rig.results.first ?? nil)
    }

    func testAUserSwitchSeenOnlyByTheWindowServerPrintsNoLine() {
        let rig = Rig { desktop in
            desktop.appKitFollows = false
        }
        rig.desktop.appKitFront = rig.editor
        rig.idle[.leftMouseDown] = 0.01
        rig.front = rig.browser
        for _ in 0..<120 { rig.advance(0.02) }
        XCTAssertNil(rig.results.first ?? nil)
        XCTAssertTrue(rig.activations.isEmpty)
    }

    func testARestoreIsConfirmedByAppKitAndAnAppAlreadyInFrontIsNotActivatedAgain() {
        let rig = Rig(keyFocusAtStart: userKeys) { desktop in
            desktop.appKitFollows = false
        }
        rig.desktop.appKitFront = rig.browser
        rig.front = rig.browser
        rig.advance(0.02)
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.windowRequests.map(\.pid), [10])
        // The window server has the editor in front at once; AppKit lags.
        XCTAssertEqual(rig.front, rig.editor)
        rig.advance(0.15)
        XCTAssertNil(rig.results.first ?? nil, "not restored until AppKit agrees")
        XCTAssertTrue(rig.activations.isEmpty, "no activation for an app the window server has in front")
        rig.desktop.appKitFront = rig.editor
        rig.advance(0.02)
        XCTAssertEqual(rig.results.first??.outcome, .restored(afterMs: 40))
    }

    func testTheReaderDecidesWithAppKitAndDetectsWithTheWindowServer() {
        let editor = FrontmostGuard.App(pid: 10, label: "com.example.editor")
        let browser = FrontmostGuard.App(pid: 20, label: "com.example.browser")
        let apps = [editor.pid: editor, browser.pid: browser]
        // The window server says the target is in front, AppKit says the user's app.
        let reader = FrontmostGuard.FrontReader(windowServerPid: { 20 }, workspacePid: { 10 }, app: { apps[$0] })
        XCTAssertEqual(reader.confirmed(), editor)
        XCTAssertEqual(reader.detected(), browser)
    }

    func testOnlyRegularAppsCountAsTheAppInFront() {
        let editor = FrontmostGuard.App(pid: 10, label: "com.example.editor")
        // Pid 40 is a system panel: the reader's app lookup knows no regular app for it.
        let apps = [editor.pid: editor]
        let panelFront = FrontmostGuard.FrontReader(windowServerPid: { 40 }, workspacePid: { 10 }, app: { apps[$0] })
        XCTAssertEqual(panelFront.detected(), editor, "a panel in front falls back to AppKit's app")
        let panelActive = FrontmostGuard.FrontReader(windowServerPid: { 40 }, workspacePid: { 40 }, app: { apps[$0] })
        XCTAssertNil(panelActive.confirmed())
        XCTAssertNil(panelActive.detected())
    }

    func testThePauseUsesAppKitsFrontmostApp() {
        // The window server says the target is in front, AppKit says the
        // user's app; the user just typed. The pause reads AppKit's answer,
        // so the action on the target is not refused.
        let reader = FrontmostGuard.FrontReader(
            windowServerPid: { 20 },
            workspacePid: { 10 },
            app: { FrontmostGuard.App(pid: $0, label: "pid \($0)") }
        )
        let seen = UserActivity.Observation(
            now: 100,
            idle: UserActivity.Idle(keyDown: 0.2, mouseDown: .infinity, scroll: .infinity),
            frontmost: reader.confirmed()?.pid
        )
        XCTAssertNil(UserActivity.decide(target: 20, seen))
    }
}

final class FocusWatchUserWindowTests: XCTestCase {
    func testAWindowTheUserOpenedDuringTheWatchIsTheOneBroughtBack() {
        let rig = Rig(keyFocusAtStart: KeyFocus.AtStart(windowId: 7, userHoldsKeys: true))
        rig.advance(0.5)
        // The user's app opened window 9; then the target came forward.
        rig.desktop.userWindowId = 9
        rig.front = rig.browser
        rig.advance(0.02)
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.windowRequests.map(\.windowId), [9])
    }
}

final class FocusWatchStopTests: XCTestCase {
    func testAStopAfterTheRequestDoesNotRaiseTheUserWindow() {
        let rig = Rig(keyFocusAtStart: KeyFocus.AtStart(windowId: 7, userHoldsKeys: true)) { desktop in
            desktop.appKitFollows = false
            desktop.userWindowBuried = true
        }
        rig.desktop.appKitFront = rig.browser
        rig.front = rig.browser
        rig.advance(0.02)
        rig.advance(0.02)
        XCTAssertEqual(rig.desktop.windowRequests.map(\.pid), [10])
        rig.watch.cancel()
        rig.desktop.appKitFront = rig.editor
        rig.advance(0.02)
        XCTAssertEqual(rig.results.first??.outcome, .restored(afterMs: 40))
        XCTAssertFalse(rig.desktop.log.contains { $0.hasPrefix("raise check") })
        XCTAssertTrue(rig.desktop.raised.isEmpty)
    }
}
