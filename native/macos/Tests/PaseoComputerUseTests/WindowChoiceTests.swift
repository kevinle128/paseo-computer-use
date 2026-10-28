import CoreGraphics
import XCTest
@testable import PaseoComputerUseCore

final class WindowChoiceTests: XCTestCase {
    private typealias Window = AXEngine.WindowCandidate

    private func info(
        id: Int,
        layer: Int = 0,
        alpha: Double = 1,
        rect: CGRect = CGRect(x: 0, y: 30, width: 800, height: 600)
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: rect.dictionaryRepresentation,
        ]
    }

    func testReportableWindowRejectsOverlayLayerTransparentAndTinyWindows() {
        XCTAssertNotNil(AXEngine.reportableWindow(info(id: 1)))
        XCTAssertNil(AXEngine.reportableWindow(info(id: 2, layer: 25)))
        XCTAssertNil(AXEngine.reportableWindow(info(id: 3, alpha: 0)))
        XCTAssertNil(AXEngine.reportableWindow(info(id: 4, rect: CGRect(x: 0, y: 0, width: 10, height: 600))))
    }

    func testFocusedWindowBeatsAFrontmostLargerWindow() {
        let popup = Window(id: 36925, bounds: CGRect(x: 100, y: 60, width: 2128, height: 218))
        let page = Window(id: 36923, bounds: CGRect(x: 0, y: 30, width: 2560, height: 1410), title: "Canvas")
        let hints = [Window(id: 0, bounds: page.bounds, title: "Canvas")]
        XCTAssertEqual(AXEngine.chooseWindow(candidates: [popup, page], hints: hints)?.id, 36923)
    }

    func testMainWindowIsUsedWhenNoWindowIsFocused() {
        let first = Window(id: 1, bounds: CGRect(x: 0, y: 0, width: 900, height: 700))
        let second = Window(id: 2, bounds: CGRect(x: 50, y: 50, width: 400, height: 300))
        let hints = [Window(id: 0, bounds: second.bounds)]
        XCTAssertEqual(AXEngine.chooseWindow(candidates: [first, second], hints: hints)?.id, 2)
    }

    func testSameFrameIsToldApartByTitle() {
        let frame = CGRect(x: 0, y: 30, width: 800, height: 600)
        let front = Window(id: 1, bounds: frame, title: "A")
        let back = Window(id: 2, bounds: frame, title: "B")
        let hints = [Window(id: 0, bounds: frame, title: "B")]
        XCTAssertEqual(AXEngine.chooseWindow(candidates: [front, back], hints: hints)?.id, 2)
    }

    func testAHintForAWindowThatIsNotReportedIsSkipped() {
        let reported = Window(id: 1, bounds: CGRect(x: 0, y: 30, width: 800, height: 600))
        let hidden = [Window(id: 0, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440))]
        XCTAssertEqual(AXEngine.chooseWindow(candidates: [reported], hints: hidden)?.id, 1)
    }

    func testTheLargestWindowIsChosenWithoutHintsAndTheFrontmostWinsATie() {
        let small = Window(id: 1, bounds: CGRect(x: 0, y: 0, width: 300, height: 300))
        let big = Window(id: 2, bounds: CGRect(x: 0, y: 0, width: 900, height: 700))
        let twin = Window(id: 3, bounds: CGRect(x: 10, y: 10, width: 900, height: 700))
        XCTAssertEqual(AXEngine.chooseWindow(candidates: [small, big, twin], hints: [])?.id, 2)
        XCTAssertNil(AXEngine.chooseWindow(candidates: [], hints: []))
    }

    func testAWindowIsMatchedByFrameAndTitle() {
        let frame = CGRect(x: 0, y: 30, width: 800, height: 600)
        let candidates = [Window(id: 1, bounds: frame, title: "A"), Window(id: 2, bounds: frame, title: "B")]
        XCTAssertEqual(AXEngine.matchWindow(frame: frame, title: "B", in: candidates)?.id, 2)
    }

    func testAFrameSharedByTwoWindowsIsNotGuessedWithoutATitle() {
        let frame = CGRect(x: 0, y: 30, width: 800, height: 600)
        let candidates = [Window(id: 1, bounds: frame, title: "A"), Window(id: 2, bounds: frame, title: "B")]
        XCTAssertNil(AXEngine.matchWindow(frame: frame, title: "C", in: candidates))
    }

    func testAnUnambiguousFrameMatchesWhateverTheTitle() {
        let candidates = [
            Window(id: 1, bounds: CGRect(x: 0, y: 30, width: 800, height: 600)),
            Window(id: 2, bounds: CGRect(x: 40, y: 70, width: 800, height: 600)),
        ]
        XCTAssertEqual(
            AXEngine.matchWindow(frame: CGRect(x: 40.5, y: 70, width: 800, height: 600), title: "x", in: candidates)?.id,
            2
        )
    }

    func testTheTitleIsTheOneTheWindowServerShowsWhenThereIsOne() {
        let window = Window(id: 1, bounds: .zero, title: "Canvas 4")
        XCTAssertEqual(AXEngine.displayTitle(window: window, axTitle: "Canvas 4 - Browser - Profile"), "Canvas 4")
        XCTAssertEqual(AXEngine.displayTitle(window: Window(id: 1, bounds: .zero, title: ""), axTitle: "From AX"), "From AX")
        XCTAssertEqual(AXEngine.displayTitle(window: Window(id: 1, bounds: .zero), axTitle: nil), "")
    }

    func testAClosedWindowIsReportedWithItsOwnCode() {
        let error = AXEngine.windowGoneError(38214)
        XCTAssertEqual(error.code, "window_gone")
        XCTAssertTrue(error.message.contains("38214"))
        XCTAssertTrue(error.message.contains("get_app_state"))
    }

    func testAWindowThatDoesNotBelongToTheAppIsNotOnScreenForIt() {
        // Window id 1 never belongs to this test process.
        XCTAssertNil(AXEngine.onScreenBounds(windowId: 1, ownerPid: getpid()))
    }
}

final class KeyWindowCheckTests: XCTestCase {
    private func check(_ state: AXEngine.FocusedWindowState, only: Bool) -> AXEngine.KeyWindowCheck {
        AXEngine.KeyWindowCheck(state: state, targetIsOnlyWindow: only)
    }

    func testAFocusedTargetAllowsKeysWhateverElseIsOpen() {
        XCTAssertTrue(check(.belongs, only: false).allowsKeys)
        XCTAssertTrue(check(.belongs, only: true).allowsKeys)
    }

    func testAnotherFocusedWindowRefusesKeysEvenForASingleWindowApp() {
        XCTAssertFalse(check(.elsewhere, only: false).allowsKeys)
        XCTAssertFalse(check(.elsewhere, only: true).allowsKeys)
    }

    func testAnAppThatDoesNotReportItsFocusedWindowIsTrustedOnlyWithOneWindow() {
        XCTAssertTrue(check(.unreported, only: true).allowsKeys)
        XCTAssertFalse(check(.unreported, only: false).allowsKeys)
    }
}

final class DefaultKeyWindowTests: XCTestCase {
    func testTheWindowOfTheLatestReadIsUsedWhileItIsOnScreen() throws {
        XCTAssertEqual(try AXEngine.defaultKeyWindow(cachedId: 7, cachedOnScreen: true, primaryId: 9), 7)
    }

    func testAClosedReadWindowStopsTheCommandInsteadOfUsingTheAppsOwnPick() {
        XCTAssertThrowsError(try AXEngine.defaultKeyWindow(cachedId: 7, cachedOnScreen: false, primaryId: 9)) { error in
            XCTAssertEqual((error as? HelperError)?.code, HelperError.windowGone)
        }
    }

    func testAnAppThatWasNeverReadUsesItsOwnPickOrNoWindow() throws {
        XCTAssertEqual(try AXEngine.defaultKeyWindow(cachedId: nil, cachedOnScreen: false, primaryId: 9), 9)
        XCTAssertEqual(try AXEngine.defaultKeyWindow(cachedId: 0, cachedOnScreen: false, primaryId: 9), 9)
        XCTAssertEqual(try AXEngine.defaultKeyWindow(cachedId: nil, cachedOnScreen: false, primaryId: nil), 0)
    }
}

final class PanelWindowTests: XCTestCase {
    private func info(id: Int, layer: Int, alpha: Double = 1, width: CGFloat = 300) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: CGRect(x: 10, y: 40, width: width, height: 200).dictionaryRepresentation,
            kCGWindowName as String: "Inspector",
        ]
    }

    func testFloatingUtilityAndModalLayersAreReadablePanels() {
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        let modal = Int(CGWindowLevelForKey(.modalPanelWindow))
        XCTAssertEqual(AXEngine.panelWindow(info(id: 1, layer: floating))?.layer, floating)
        XCTAssertEqual(AXEngine.panelWindow(info(id: 2, layer: modal))?.id, 2)
        XCTAssertEqual(AXEngine.panelWindow(info(id: 2, layer: modal))?.title, "Inspector")
    }

    func testMenuBarStatusItemAndPopupMenuLayersAreNotPanels() {
        for key in [CGWindowLevelKey.mainMenuWindow, .statusWindow, .popUpMenuWindow, .overlayWindow] {
            XCTAssertNil(AXEngine.panelWindow(info(id: 3, layer: Int(CGWindowLevelForKey(key)))))
        }
    }

    func testANormalWindowTransparentOrTinyPanelIsNotAPanel() {
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        XCTAssertNil(AXEngine.panelWindow(info(id: 4, layer: 0)))
        XCTAssertNil(AXEngine.panelWindow(info(id: 5, layer: floating, alpha: 0)))
        XCTAssertNil(AXEngine.panelWindow(info(id: 6, layer: floating, width: 10)))
    }

    func testAnAppModalPanelAboveTheTargetTakesKeysButAFloatingPaletteDoesNot() {
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        let modal = Int(CGWindowLevelForKey(.modalPanelWindow))
        XCTAssertTrue(AXEngine.panelTakesKeys(panelLayer: modal, targetLayer: 0, axModal: false))
        XCTAssertTrue(AXEngine.panelTakesKeys(panelLayer: floating, targetLayer: 0, axModal: true))
        XCTAssertFalse(AXEngine.panelTakesKeys(panelLayer: floating, targetLayer: 0, axModal: false))
        XCTAssertFalse(AXEngine.panelTakesKeys(panelLayer: modal, targetLayer: modal, axModal: true))
    }
}

final class WindowScopePanelTests: XCTestCase {
    private let target = CGRect(x: 0, y: 30, width: 800, height: 600)

    func testAPanelOverTheTargetIsReadWithIt() {
        let alert = AXEngine.WindowCandidate(id: 2, bounds: CGRect(x: 200, y: 200, width: 300, height: 150), layer: 8)
        XCTAssertTrue(AXEngine.WindowScope.isWalkedPanel(alert, over: target))
    }

    func testAPanelAwayFromTheTargetIsOnlyListed() {
        let palette = AXEngine.WindowCandidate(id: 3, bounds: CGRect(x: 900, y: 30, width: 200, height: 400), layer: 3)
        XCTAssertFalse(AXEngine.WindowScope.isWalkedPanel(palette, over: target))
    }

    func testANormalWindowOverTheTargetIsOnlyListed() {
        let other = AXEngine.WindowCandidate(id: 4, bounds: CGRect(x: 100, y: 100, width: 300, height: 300))
        XCTAssertFalse(AXEngine.WindowScope.isWalkedPanel(other, over: target))
    }
}

final class SuggestionDropdownTests: XCTestCase {
    private let target = CGRect(x: 0, y: 30, width: 800, height: 600)
    private let dropdown = CGRect(x: 120, y: 70, width: 500, height: 220)
    private let list = ["AXList"]

    private func matches(
        title: String? = nil,
        layer: Int = 0,
        bounds: CGRect? = nil,
        roles: [String]? = nil
    ) -> Bool {
        let window = AXEngine.WindowCandidate(id: 9, bounds: bounds ?? dropdown, title: title, layer: layer)
        return AXEngine.WindowScope.isSuggestionDropdown(window, over: target) { roles ?? list }
    }

    func testAnUntitledWindowOfOnlyListRolesUnderTheToolbarMatches() {
        XCTAssertTrue(matches())
        XCTAssertTrue(matches(title: "  ", roles: ["AXList", "AXRow", "AXCell", "AXStaticText"]))
        XCTAssertTrue(matches(layer: 3))
    }

    func testAPromptWithAButtonOrFieldDoesNotMatch() {
        XCTAssertFalse(matches(roles: ["AXStaticText", "AXButton"]))
        XCTAssertFalse(matches(roles: ["AXGroup"]))
        XCTAssertFalse(matches(roles: ["AXTextField"]))
    }

    func testAWindowWithNoReadableChildrenDoesNotMatch() {
        XCTAssertFalse(matches(roles: []))
    }

    func testAWindowWithATitleDoesNotMatch() {
        XCTAssertFalse(matches(title: "Settings"))
    }

    func testAnAppModalPanelNeverMatches() {
        XCTAssertFalse(matches(layer: AXEngine.modalPanelLayer))
    }

    func testAWindowAwayFromTheToolbarDoesNotMatch() {
        XCTAssertFalse(matches(bounds: CGRect(x: 100, y: 500, width: 300, height: 100)))
        XCTAssertFalse(matches(bounds: CGRect(x: 900, y: 70, width: 300, height: 100)))
    }

    func testTheChildrenAreNotReadForAWindowTheCheapTestsRefuse() {
        var read = false
        let window = AXEngine.WindowCandidate(id: 9, bounds: CGRect(x: 100, y: 500, width: 300, height: 100), title: nil, layer: 0)
        _ = AXEngine.WindowScope.isSuggestionDropdown(window, over: target) { read = true; return [] }
        XCTAssertFalse(read)
    }
}

final class IndistinguishableWindowsTests: XCTestCase {
    func testWindowsWithTheSameFrameAndNoTitleAreNotMatched() {
        let frame = CGRect(x: 0, y: 30, width: 800, height: 600)
        let candidates = [
            AXEngine.WindowCandidate(id: 1, bounds: frame),
            AXEngine.WindowCandidate(id: 2, bounds: frame),
        ]
        XCTAssertNil(AXEngine.matchWindow(frame: frame, title: nil, in: candidates))
    }

    func testAnUnseenTargetBesideWindowsWithoutIdsIsAnError() {
        XCTAssertTrue(AXEngine.WindowScope.hidTarget(targetSeen: false, unidentified: 2))
    }

    func testASeenTargetOrAnAppWithoutWindowsIsNotAnError() {
        XCTAssertFalse(AXEngine.WindowScope.hidTarget(targetSeen: true, unidentified: 2))
        XCTAssertFalse(AXEngine.WindowScope.hidTarget(targetSeen: false, unidentified: 0))
    }
}
