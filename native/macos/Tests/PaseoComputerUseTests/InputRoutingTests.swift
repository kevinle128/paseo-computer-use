import Carbon.HIToolbox
import XCTest
@testable import PaseoComputerUseCore

final class InputRoutingTests: XCTestCase {
    private let abc = InputSourceStatus(inputSourceId: "com.apple.keylayout.ABC", isInputMethod: false, isKeyboardLayout: true)
    private let telex = InputSourceStatus(
        inputSourceId: "com.apple.inputmethod.VietnameseIM.VietnameseSimpleTelex",
        isInputMethod: true,
        isKeyboardLayout: false
    )
    private let vni = InputSourceStatus(
        inputSourceId: "com.apple.inputmethod.VietnameseIM.VietnameseVNI",
        isInputMethod: true,
        isKeyboardLayout: false
    )

    func testPlainLayoutTypesKeystrokes() {
        XCTAssertFalse(InputDriver.typesByPasting(source: abc, allowInputMethod: false))
    }

    func testTelexAndVniPaste() {
        XCTAssertTrue(InputDriver.typesByPasting(source: telex, allowInputMethod: false))
        XCTAssertTrue(InputDriver.typesByPasting(source: vni, allowInputMethod: false))
    }

    func testAllowInputMethodKeepsKeystrokes() {
        XCTAssertFalse(InputDriver.typesByPasting(source: telex, allowInputMethod: true))
    }

    func testKeyWindowRecordsNameTheWindowInTwoSteps() {
        let records = InputDriver.keyWindowRecords(windowId: 0x0102_0304)
        XCTAssertEqual(records.count, 2)
        for (index, record) in records.enumerated() {
            XCTAssertEqual(record.count, 0xF8)
            XCTAssertEqual(record[0x04], 0xF8)
            XCTAssertEqual(record[0x08], UInt8(index + 1))
            XCTAssertEqual(record[0x3A], 0x10)
            XCTAssertEqual(Array(record[0x20..<0x30]), [UInt8](repeating: 0xFF, count: 16))
            // Little-endian window id.
            XCTAssertEqual(Array(record[0x3C..<0x40]), [0x04, 0x03, 0x02, 0x01])
        }
    }

    func testKnownKeysParse() throws {
        let (save, saveFlags) = try InputDriver.parseKeyChord("Command+s")
        XCTAssertEqual(save, CGKeyCode(kVK_ANSI_S))
        XCTAssertTrue(saveFlags.contains(.maskCommand))
        XCTAssertEqual(try InputDriver.parseKeyChord("cmd+/").0, CGKeyCode(kVK_ANSI_Slash))
        XCTAssertEqual(try InputDriver.parseKeyChord("F5").0, CGKeyCode(kVK_F5))
        XCTAssertEqual(try InputDriver.parseKeyChord("Return").0, CGKeyCode(kVK_Return))
    }

    func testUnknownKeyIsAnErrorNotReturn() {
        for chord in ["NotAKey", "cmd+", "hyper+s", "shift", ""] {
            XCTAssertThrowsError(try InputDriver.parseKeyChord(chord), chord) { error in
                XCTAssertEqual((error as? HelperError)?.code, HelperError.malformedRequest, chord)
            }
        }
    }

    func testSpaceAndPlusKeysParse() throws {
        XCTAssertEqual(try InputDriver.parseKeyChord(" ").0, CGKeyCode(kVK_Space))
        XCTAssertEqual(try InputDriver.parseKeyChord("cmd+ ").0, CGKeyCode(kVK_Space))
        XCTAssertEqual(try InputDriver.parseKeyChord("space").0, CGKeyCode(kVK_Space))

        let (plus, plusFlags) = try InputDriver.parseKeyChord("cmd++")
        XCTAssertEqual(plus, CGKeyCode(kVK_ANSI_Equal))
        XCTAssertTrue(plusFlags.contains(.maskCommand))
        XCTAssertTrue(plusFlags.contains(.maskShift))

        let (bare, bareFlags) = try InputDriver.parseKeyChord("+")
        XCTAssertEqual(bare, CGKeyCode(kVK_ANSI_Equal))
        XCTAssertEqual(bareFlags, .maskShift)
    }

    func testInputSourceTypeClassification() {
        let telexMode = InputDriver.classifyInputSource(
            id: "com.apple.inputmethod.VietnameseIM.VietnameseSimpleTelex",
            type: kTISTypeKeyboardInputMode as String
        )
        XCTAssertTrue(telexMode.isInputMethod)
        XCTAssertFalse(telexMode.isKeyboardLayout)

        // A third-party input method whose id does not say "inputmethod" is
        // still recognised by its TIS type.
        let modeByType = InputDriver.classifyInputSource(id: "org.example.ime.mode", type: kTISTypeKeyboardInputMode as String)
        XCTAssertTrue(modeByType.isInputMethod)
        let withoutModes = InputDriver.classifyInputSource(id: "org.example.ime", type: kTISTypeKeyboardInputMethodWithoutModes as String)
        XCTAssertTrue(withoutModes.isInputMethod)
        let modeEnabled = InputDriver.classifyInputSource(id: "org.example.ime", type: kTISTypeKeyboardInputMethodModeEnabled as String)
        XCTAssertTrue(modeEnabled.isInputMethod)

        let layout = InputDriver.classifyInputSource(id: "com.apple.keylayout.ABC", type: kTISTypeKeyboardLayout as String)
        XCTAssertFalse(layout.isInputMethod)
        XCTAssertTrue(layout.isKeyboardLayout)
        XCTAssertFalse(InputDriver.typesByPasting(source: layout, allowInputMethod: false))
        XCTAssertTrue(InputDriver.typesByPasting(source: telexMode, allowInputMethod: false))

        let unknownType = InputDriver.classifyInputSource(id: "com.apple.inputmethod.Kotoeri", type: nil)
        XCTAssertTrue(unknownType.isInputMethod)
    }

    func testUnknownHoldKeyIsAnError() {
        XCTAssertThrowsError(try InputDriver.eventFlags(for: ["Command", "Hyper"]))
    }

    func testTheWindowANameCommandTargetsComesFromWindowId() {
        XCTAssertEqual(InputDriver.requestedWindowId(["windowId": 38214]), 38214)
        XCTAssertNil(InputDriver.requestedWindowId([:]))
        XCTAssertNil(InputDriver.requestedWindowId(["windowId": "38214"]))
    }
}

final class TypingFocusTests: XCTestCase {
    private func check(_ state: AXEngine.FocusedWindowState) -> AXEngine.KeyWindowCheck {
        AXEngine.KeyWindowCheck(state: state, targetIsOnlyWindow: false)
    }

    func testTypingStopsOnlyWhenAnotherWindowIsReportedAsFocused() {
        XCTAssertTrue(InputDriver.typingMustStop(check(.elsewhere)))
        XCTAssertFalse(InputDriver.typingMustStop(check(.belongs)))
        XCTAssertFalse(InputDriver.typingMustStop(check(.unreported)))
    }

    func testTheTypedCountIsInCharactersNotUtf16Units() {
        XCTAssertEqual(InputDriver.typedCharacterCount("abcdef", utf16Units: 4), 4)
        // Each emoji is two UTF-16 units.
        XCTAssertEqual(InputDriver.typedCharacterCount("😀😀😀", utf16Units: 4), 2)
        XCTAssertEqual(InputDriver.typedCharacterCount("abc", utf16Units: 0), 0)
    }

    func testAWindowSwitchDuringTypingIsAUserActiveRefusal() {
        let error = InputDriver.typingStoppedError(appName: "Notes", text: "😀😀😀abc", typedUTF16Units: 4)
        XCTAssertEqual(error.code, HelperError.userActive)
        XCTAssertNotEqual(error.code, HelperError.userIntervened)
        XCTAssertNotEqual(error.code, HelperError.abortedByUser)
        XCTAssertTrue(error.message.contains("Typed 2 of 6 characters; the rest was not sent."), error.message)
        XCTAssertTrue(error.message.contains("call get_app_state again"), error.message)
        XCTAssertTrue(error.message.hasPrefix("Notes moved its focus to another window"), error.message)
    }
}

/// Focus confirmation for a named element, with a tree of plain values and no
/// accessibility call.
final class ElementFocusTests: XCTestCase {
    // 1 is the window, 2 a group in it, 3 a field in the group, 4 a sibling field.
    private let parents: [Int: Int] = [2: 1, 3: 2, 4: 1]

    private func within(focused: Int?, target: Int, maxDepth: Int = 24) -> Bool {
        InputDriver.focusIsWithin(
            focused: focused,
            target: target,
            parent: { parents[$0] },
            same: ==,
            maxDepth: maxDepth
        )
    }

    func testTheNamedElementHoldingFocusPasses() {
        XCTAssertTrue(within(focused: 3, target: 3))
    }

    func testFocusOnADescendantOfTheNamedElementPasses() {
        XCTAssertTrue(within(focused: 3, target: 2))
    }

    func testFocusOnASiblingOrAParentFails() {
        XCTAssertFalse(within(focused: 4, target: 3))
        XCTAssertFalse(within(focused: 2, target: 3))
    }

    func testNoFocusedElementFails() {
        XCTAssertFalse(within(focused: nil, target: 3))
    }

    func testAParentLoopEndsAtTheDepthLimit() {
        let looping = InputDriver.focusIsWithin(focused: 1, target: 9, parent: { _ in 1 }, same: ==, maxDepth: 5)
        XCTAssertFalse(looping)
    }
}

/// The key window step for an app that is not in front: the records are posted
/// again, the check is polled a bounded number of times, and nothing is sent
/// when the target never becomes the key window.
final class KeyWindowSettleTests: XCTestCase {
    private func check(
        _ state: AXEngine.FocusedWindowState,
        only: Bool = false,
        reported: Int? = nil
    ) -> AXEngine.KeyWindowCheck {
        AXEngine.KeyWindowCheck(state: state, targetIsOnlyWindow: only, focusedWindowId: reported)
    }

    private final class Rig {
        var answers: [AXEngine.KeyWindowCheck]
        var posts: [Int] = []
        var polls = 0
        var sleeps = 0
        /// A fake clock in seconds.
        var time = 0.0
        /// Accessibility requests one check makes, and the seconds each takes.
        var requestsPerCheck = 5
        var secondsPerRequest = 0.0
        var secondsPerSleep = 0.02
        /// Called before each fake request, after its checkpoint.
        var onRequest: (() -> Void)?
        var requests = 0
        init(_ answers: [AXEngine.KeyWindowCheck]) { self.answers = answers }

        func run(tries: Int = 15, limit: Double = 1.5) throws -> AXEngine.KeyWindowCheck? {
            try InputDriver.settleKeyWindow(
                post: { self.posts.append($0) },
                check: { checkpoint in
                    self.polls += 1
                    for _ in 0..<self.requestsPerCheck {
                        try checkpoint()
                        self.requests += 1
                        self.onRequest?()
                        self.time += self.secondsPerRequest
                    }
                    return self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0]
                },
                sleep: {
                    self.sleeps += 1
                    self.time += self.secondsPerSleep
                },
                tries: tries,
                now: { self.time },
                limit: limit
            )
        }
    }

    func testAFocusedWindowThatAppearsAfterSomePollsAllowsKeys() throws {
        let rig = Rig([
            check(.elsewhere, reported: 41402), check(.unreported), check(.belongs),
        ])
        XCTAssertNil(try rig.run())
        XCTAssertEqual(rig.polls, 3)
        XCTAssertEqual(rig.sleeps, 2)
        XCTAssertEqual(rig.posts, [0, 1, 2], "the records are posted again before each poll")
    }

    func testAWindowThatIsAlreadyFocusedNeedsOnePostAndOnePoll() throws {
        let rig = Rig([check(.belongs)])
        XCTAssertNil(try rig.run())
        XCTAssertEqual(rig.polls, 1)
        XCTAssertEqual(rig.sleeps, 0)
    }

    func testAWindowThatNeverBecomesKeyIsRefusedAfterTheBound() throws {
        let rig = Rig([check(.elsewhere, reported: 41402)])
        let refused = try rig.run(tries: 15)
        XCTAssertEqual(refused?.state, .elsewhere)
        XCTAssertEqual(rig.polls, 15)
        XCTAssertEqual(rig.sleeps, 14)
    }

    func testAHungAppIsRefusedWithinTheLimitEvenInTheMiddleOfATry() throws {
        // Each request blocks for the 1 s messaging timeout.
        let rig = Rig([check(.elsewhere, reported: 41402)])
        rig.secondsPerRequest = 1.0
        let refused = try rig.run()
        XCTAssertEqual(refused?.state, .noAnswer)
        XCTAssertEqual(rig.polls, 1)
        XCTAssertEqual(rig.requests, 2, "the check stops at the first request after 1.5 s")
        XCTAssertLessThanOrEqual(rig.time, 2.0)
    }

    func testASlowAppIsRefusedWhenTheLimitPassesBetweenTries() throws {
        let rig = Rig([check(.elsewhere, reported: 41402)])
        rig.secondsPerRequest = 0.05
        let refused = try rig.run()
        XCTAssertEqual(refused?.state, .noAnswer)
        XCTAssertLessThan(rig.polls, 15)
        XCTAssertLessThan(rig.time, 1.6)
    }

    func testACancelStopsTheCheckBetweenTwoRequests() throws {
        let token = CommandCancellation()
        let rig = Rig([check(.elsewhere)])
        rig.onRequest = { if rig.requests == 2 { token.cancel() } }
        XCTAssertThrowsError(try CommandCancellation.run(with: token) { try rig.run() }) { error in
            XCTAssertEqual((error as? HelperError)?.code, HelperError.abortedByUser)
        }
        XCTAssertEqual(rig.polls, 1)
        XCTAssertEqual(rig.requests, 2, "no request is made after the cancel")
    }

    func testAnAppThatDoesNotAnswerInTimeNeverGetsKeysOrStopsTyping() {
        let noAnswer = check(.noAnswer, only: true)
        XCTAssertFalse(noAnswer.allowsKeys)
        XCTAssertFalse(InputDriver.typingMustStop(noAnswer))
    }

    func testAnAppThatReportsNoFocusedWindowIsRefusedWhenItHasOtherWindows() throws {
        XCTAssertNotNil(try Rig([check(.unreported, only: false)]).run(tries: 3))
    }

    func testAnAppThatReportsNoFocusedWindowIsTrustedWhenTheTargetIsItsOnlyWindow() throws {
        let rig = Rig([check(.unreported, only: true)])
        XCTAssertNil(try rig.run())
        XCTAssertEqual(rig.polls, 1)
    }

    func testTheRefusalNamesTheWindowTheAppReportsAndTheAlternatives() {
        let alternatives = "No keys were sent. To act in that window, use click, secondary_action, or set_value on its elements, or ask the user."
        XCTAssertEqual(
            InputDriver.couldNotFocusReason(windowId: 41409, check: check(.elsewhere, reported: 41402)),
            "could not focus window [41409] (the app reports [41402] as focused). " + alternatives
        )
        XCTAssertEqual(
            InputDriver.couldNotFocusReason(windowId: 41409, check: check(.unreported)),
            "could not focus window [41409] (the app reports no focused window). " + alternatives
        )
        XCTAssertEqual(
            InputDriver.couldNotFocusReason(windowId: 41409, check: check(.noAnswer)),
            "could not focus window [41409] (the app did not answer in time). " + alternatives
        )
    }
}

final class CloseWindowChordTests: XCTestCase {
    private func isClose(_ chord: String) throws -> Bool {
        let (code, flags) = try InputDriver.parseKeyChord(chord)
        return InputDriver.isCloseWindowChord(keyCode: code, flags: flags)
    }

    func testOnlyCommandWAloneIsTheCloseWindowChord() throws {
        XCTAssertTrue(try isClose("cmd+w"))
        XCTAssertTrue(try isClose("Command+W"))
        XCTAssertFalse(try isClose("cmd+shift+w"))
        XCTAssertFalse(try isClose("cmd+alt+w"))
        XCTAssertFalse(try isClose("ctrl+w"))
        XCTAssertFalse(try isClose("cmd+q"))
        XCTAssertFalse(try isClose("w"))
    }
}

final class CloseWithButtonTests: XCTestCase {
    /// A fake close button and window: no accessibility call, no event.
    private final class Rig {
        var hasButton = true
        var enabled = true
        var pressResult = InputDriver.PressResult.accepted
        var waitsAfterTimeout = true
        /// How many checks see the window before it is gone; nil keeps it.
        var visibleChecks: Int? = 0
        var presses = 0
        var checks = 0
        var sleeps = 0

        func run(tries: Int = 25) throws -> InputDriver.CloseButtonOutcome {
            try InputDriver.closeWithButton(
                button: { self.hasButton ? "close" : nil },
                isEnabled: { _ in self.enabled },
                press: { _ in
                    self.presses += 1
                    return self.pressResult
                },
                gone: {
                    self.checks += 1
                    guard let visible = self.visibleChecks else { return false }
                    return self.checks > visible
                },
                waitsAfterTimeout: waitsAfterTimeout,
                sleep: { self.sleeps += 1 },
                tries: tries
            )
        }
    }

    func testAnEnabledButtonIsPressedOnceAndTheWindowIsSeenGone() throws {
        let rig = Rig()
        rig.visibleChecks = 2
        XCTAssertEqual(try rig.run(), .closed)
        XCTAssertEqual(rig.presses, 1)
        XCTAssertEqual(rig.checks, 3)
        XCTAssertEqual(rig.sleeps, 2)
    }

    func testAWindowThatStaysOpenIsReportedAfterTheBound() throws {
        let rig = Rig()
        rig.visibleChecks = nil
        XCTAssertEqual(try rig.run(tries: 5), .stillOpen)
        XCTAssertEqual(rig.presses, 1)
        XCTAssertEqual(rig.checks, 5)
        XCTAssertEqual(rig.sleeps, 4)
    }

    func testNoButtonADisabledButtonOrARefusedPressIsUnavailable() throws {
        let missing = Rig()
        missing.hasButton = false
        XCTAssertEqual(try missing.run(), .unavailable)
        XCTAssertEqual(missing.presses, 0)

        let disabled = Rig()
        disabled.enabled = false
        XCTAssertEqual(try disabled.run(), .unavailable)
        XCTAssertEqual(disabled.presses, 0, "a disabled button is never pressed")

        let refused = Rig()
        refused.pressResult = .refused
        XCTAssertEqual(try refused.run(), .unavailable)
        XCTAssertEqual(refused.checks, 0)
    }

    func testAPressThatTimedOutCountsAsPressedAndIsWaitedFor() throws {
        let closes = Rig()
        closes.pressResult = .timedOut
        closes.visibleChecks = 3
        XCTAssertEqual(try closes.run(), .closed, "the window closed after the timed out press")

        let stays = Rig()
        stays.pressResult = .timedOut
        stays.visibleChecks = nil
        XCTAssertEqual(try stays.run(tries: 4), .unknown, "never reported as still open or as not pressed")
        XCTAssertEqual(stays.checks, 4)
    }

    func testAPressThatTimedOutIsNotWaitedForWhenTheCheckWouldAskTheHungApp() throws {
        let rig = Rig()
        rig.pressResult = .timedOut
        rig.waitsAfterTimeout = false
        XCTAssertEqual(try rig.run(), .unknown)
        XCTAssertEqual(rig.checks, 0)
        XCTAssertEqual(rig.sleeps, 0)
    }

    func testThePressResultComesFromTheAccessibilityError() {
        XCTAssertEqual(InputDriver.PressResult(.success), .accepted)
        XCTAssertEqual(InputDriver.PressResult(.cannotComplete), .timedOut)
        XCTAssertEqual(InputDriver.PressResult(.actionUnsupported), .refused)
        XCTAssertEqual(InputDriver.PressResult(.invalidUIElement), .refused)
    }

    func testTheReasonsMatchWhatThePluginExpects() {
        XCTAssertEqual(InputDriver.closedWithCloseButtonReason, "closed with its close button")
        XCTAssertEqual(
            InputDriver.closeButtonLeftWindowOpenReason(windowId: 41580),
            "pressed the close button of window [41580]; the window is still open"
        )
        XCTAssertEqual(
            InputDriver.closedTabReason(windowId: 41580),
            "closed the selected tab of window [41580] with its close button"
        )
        XCTAssertEqual(
            InputDriver.closeButtonLeftTabOpenReason(windowId: 41580),
            "pressed the close button of the selected tab of window [41580]; the tab is still open"
        )
        XCTAssertEqual(InputDriver.closeButtonPressedStateUnknownReason, "close button pressed, window state unknown")
    }
}

/// What Command+w stands for in a window it cannot reach, decided on fake
/// accessibility trees.
final class CloseControlTests: XCTestCase {
    private final class Element {
        let role: String
        var subrole: String?
        var title: String?
        var desc: String?
        var selected = false
        var children: [Element]

        init(_ role: String, subrole: String? = nil, title: String? = nil, desc: String? = nil, selected: Bool = false, _ children: [Element] = []) {
            self.role = role
            self.subrole = subrole
            self.title = title
            self.desc = desc
            self.selected = selected
            self.children = children
        }
    }

    private var reads = 0

    private lazy var tree = CloseControl<Element>.Tree(
        role: { self.reads += 1; return $0.role },
        subrole: { self.reads += 1; return $0.subrole },
        names: { [$0.title, $0.desc].compactMap { $0 } },
        isSelected: { $0.selected },
        children: { self.reads += 1; return $0.children }
    )

    private func closeButton(_ name: String = "Close") -> Element {
        Element("AXButton", desc: name)
    }

    /// A tab as Chrome reports it: a radio button with the tab button
    /// subrole, holding its close button.
    private func tab(_ title: String, selected: Bool = false, closable: Bool = true) -> Element {
        Element("AXRadioButton", subrole: "AXTabButton", title: title, selected: selected, closable ? [closeButton()] : [])
    }

    private func page(_ children: [Element] = [Element("AXStaticText", title: "Hello")]) -> Element {
        Element("AXWebArea", children)
    }

    private func browserWindow(tabs: [Element], page: Element) -> Element {
        Element("AXWindow", [
            Element("AXGroup", [
                Element("AXGroup", [Element("AXTabGroup", tabs)]),
                Element("AXToolbar", [Element("AXButton", desc: "Back"), Element("AXTextField", title: "Address")]),
                Element("AXGroup", [page]),
            ]),
            Element("AXButton", subrole: "AXCloseButton"),
        ])
    }

    private func decide(_ window: Element, maxNodes: Int = CloseControl<Element>.maxNodes) -> CloseControl<Element> {
        CloseControl.decide(window: window, tree: tree, maxNodes: maxNodes, checkpoint: {})
    }

    private func pressedButton(_ control: CloseControl<Element>) -> Element? {
        if case .tab(let button) = control { return button }
        return nil
    }

    private func isWindow(_ control: CloseControl<Element>) -> Bool {
        if case .window = control { return true }
        return false
    }

    private func isRefused(_ control: CloseControl<Element>) -> Bool {
        if case .refuse = control { return true }
        return false
    }

    func testAChromeWindowWithThreeTabsPressesTheSelectedTabsCloseButton() {
        let selected = tab("Docs", selected: true)
        let window = browserWindow(tabs: [tab("Mail"), selected, tab("News")], page: page())
        XCTAssertTrue(pressedButton(decide(window)) === selected.children[0])
    }

    func testAWindowWithOneTabUsesTheWindowCloseButton() {
        let window = browserWindow(tabs: [tab("Docs", selected: true)], page: page())
        XCTAssertTrue(isWindow(decide(window)))
    }

    func testTabsWithoutACloseButtonAreRefused() {
        let window = browserWindow(
            tabs: [tab("Mail", closable: false), tab("Docs", selected: true, closable: false), tab("News", closable: false)],
            page: page()
        )
        XCTAssertTrue(isRefused(decide(window)))
    }

    func testAWindowWithNoTabBarUsesTheWindowCloseButton() {
        // A mail viewer: the message is a web area with no tab list.
        let window = Element("AXWindow", [
            Element("AXToolbar", [Element("AXButton", desc: "Reply")]),
            Element("AXScrollArea", [page([Element("AXGroup", [Element("AXLink", title: "Unsubscribe")])])]),
        ])
        XCTAssertTrue(isWindow(decide(window)))
    }

    func testATabListInsideThePageDoesNotCountAsBrowserTabs() {
        // One browser tab; the page has its own tab list of three.
        let pageTabs = Element("AXTabGroup", [
            Element("AXRadioButton", title: "Overview", selected: true, [closeButton()]),
            Element("AXRadioButton", title: "Specs"),
            Element("AXRadioButton", title: "Reviews"),
        ])
        let window = browserWindow(tabs: [tab("Shop", selected: true)], page: page([pageTabs]))
        XCTAssertTrue(isWindow(decide(window)))
    }

    func testThreeBrowserTabsAndAPageTabListPressTheBrowserTabsButton() {
        let pageTabs = Element("AXTabGroup", [
            Element("AXRadioButton", title: "A", selected: true, [closeButton()]),
            Element("AXRadioButton", title: "B", [closeButton()]),
        ])
        let selected = tab("Shop", selected: true)
        let window = browserWindow(tabs: [tab("Mail"), selected, tab("News")], page: page([pageTabs]))
        XCTAssertTrue(pressedButton(decide(window)) === selected.children[0])
    }

    func testTheWebAreasAreNotReadWhenTheBrowserHasATabBar() {
        let huge = page((0..<5_000).map { _ in Element("AXStaticText") })
        let window = browserWindow(tabs: [tab("A"), tab("B", selected: true)], page: huge)
        XCTAssertNotNil(pressedButton(decide(window)))
        XCTAssertLessThan(reads, 200)
    }

    func testTabsDrawnInAWebAreaAreFoundWhenTheAppHasNoNativeTabBar() {
        // An Electron editor: its whole interface is a web area.
        let selected = Element("AXRadioButton", subrole: "AXTabButton", title: "main.ts", selected: true, [closeButton("Close")])
        let window = Element("AXWindow", [
            page([Element("AXGroup", [Element("AXTabGroup", [
                Element("AXRadioButton", subrole: "AXTabButton", title: "README.md", [closeButton()]),
                selected,
            ])])]),
        ])
        XCTAssertTrue(pressedButton(decide(window)) === selected.children[0])
    }

    func testTabsGroupedInsideTheTabBarAreCounted() {
        let selected = tab("B", selected: true)
        let window = browserWindow(tabs: [Element("AXGroup", title: "Work", [tab("A"), selected])], page: page())
        XCTAssertTrue(pressedButton(decide(window)) === selected.children[0])
    }

    func testABarOfTabButtonsThatIsNotATabGroupIsATabBar() {
        let selected = tab("B", selected: true)
        selected.children = [closeButton("Close Tab")]
        let window = Element("AXWindow", [Element("AXGroup", [tab("A"), selected])])
        XCTAssertTrue(pressedButton(decide(window)) === selected.children[0])
    }

    func testNoSelectedTabOrTwoSelectedTabsOrTwoCloseButtonsAreRefused() {
        XCTAssertTrue(isRefused(decide(browserWindow(tabs: [tab("A"), tab("B")], page: page()))))
        XCTAssertTrue(isRefused(decide(browserWindow(tabs: [tab("A", selected: true), tab("B", selected: true)], page: page()))))
        let twoButtons = tab("B", selected: true)
        twoButtons.children.append(closeButton("close"))
        XCTAssertTrue(isRefused(decide(browserWindow(tabs: [tab("A"), twoButtons], page: page()))))
    }

    func testAButtonWithAnotherNameIsNotTheTabsCloseButton() {
        let selected = tab("B", selected: true)
        selected.children = [Element("AXButton", desc: "Mute tab"), Element("AXButton", desc: "Closed captions")]
        XCTAssertTrue(isRefused(decide(browserWindow(tabs: [tab("A"), selected], page: page()))))
    }

    func testAWindowTooLargeToReadWithinTheBudgetIsRefused() {
        let window = Element("AXWindow", (0..<50).map { _ in Element("AXGroup") })
        XCTAssertTrue(isRefused(decide(window, maxNodes: 20)))
        XCTAssertTrue(isWindow(decide(window, maxNodes: 100)))
    }

    func testTheCheckpointStopsTheWalk() {
        struct Stop: Error {}
        var calls = 0
        let window = browserWindow(tabs: [tab("A"), tab("B", selected: true)], page: page())
        XCTAssertThrowsError(try CloseControl.decide(window: window, tree: tree, checkpoint: {
            calls += 1
            if calls == 3 { throw Stop() }
        })) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(calls, 3)
    }
}

final class TargetHoldsKeyTests: XCTestCase {
    private func holds(
        _ state: AXEngine.FocusedWindowState,
        ordinary: Bool = true,
        _ flags: AXEngine.TargetWindowFlags?
    ) -> Bool {
        AXEngine.targetHoldsKey(state: state, focusedIsOrdinary: ordinary, flags: { flags })
    }

    func testAnAppWithNoFocusedWindowIsTakenFromTheTargetsOwnFlags() {
        XCTAssertTrue(holds(.unreported, .init(focused: nil, main: true)))
        XCTAssertTrue(holds(.unreported, .init(focused: true, main: false)))
        XCTAssertFalse(holds(.unreported, .init(focused: false, main: false)))
        XCTAssertFalse(holds(.unreported, nil))
    }

    func testAStaleAnswerNamingAnotherOrdinaryWindowIsSetAsideOnlyByTheTargetsFlags() {
        XCTAssertTrue(holds(.elsewhere, .init(focused: nil, main: true)))
        XCTAssertFalse(holds(.elsewhere, .init(focused: false, main: false)))
    }

    func testAPanelOrSheetOfAnotherWindowKeepsTheKeysWhateverTheTargetSays() {
        XCTAssertFalse(holds(.elsewhere, ordinary: false, .init(focused: true, main: true)))
    }

    func testTheFlagsAreNotReadWhenTheAnswerIsAlreadyDecided() {
        var read = false
        XCTAssertFalse(AXEngine.targetHoldsKey(state: .elsewhere, focusedIsOrdinary: false, flags: { read = true; return nil }))
        XCTAssertFalse(read)
    }
}
