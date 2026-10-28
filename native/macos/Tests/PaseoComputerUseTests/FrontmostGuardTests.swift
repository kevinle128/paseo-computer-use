import XCTest
@testable import PaseoComputerUseCore

final class FrontmostGuardTests: XCTestCase {
    private let editor = FrontmostGuard.App(pid: 10, label: "com.example.editor")
    private let browser = FrontmostGuard.App(pid: 20, label: "com.example.browser")

    func testNoChangeWhenTheSameAppIsInFrontAfterwards() {
        XCTAssertNil(FrontmostGuard.change(before: editor, after: editor))
        XCTAssertNil(FrontmostGuard.change(before: nil, after: nil))
    }

    func testAChangedFrontmostAppIsNamedOldToNew() {
        XCTAssertEqual(
            FrontmostGuard.change(before: editor, after: browser),
            "user_focus_changed: com.example.editor -> com.example.browser"
        )
    }

    func testNoLineWhenNoRegularAppIsInFrontOnEitherSide() {
        XCTAssertNil(FrontmostGuard.change(before: nil, after: browser))
        XCTAssertNil(FrontmostGuard.change(before: editor, after: nil))
        XCTAssertEqual(
            FrontmostGuard.unknownFront(before: nil, after: browser),
            "front_app_unknown: none -> com.example.browser"
        )
        XCTAssertEqual(
            FrontmostGuard.unknownFront(before: editor, after: nil, suffix: FrontmostGuard.sincePreviousSuffix),
            "front_app_unknown: com.example.editor -> none (since the previous action)"
        )
        XCTAssertNil(FrontmostGuard.unknownFront(before: editor, after: browser), "a change between known apps is a line")
        XCTAssertNil(FrontmostGuard.unknownFront(before: nil, after: nil))
    }

    private func reader(_ apps: [FrontmostGuard.App?]) -> () -> FrontmostGuard.App? {
        var queue = apps
        return { queue.isEmpty ? nil : queue.removeFirst() }
    }

    func testTheResultOfAnActionCarriesTheChange() throws {
        let result = try FrontmostGuard().run(read: reader([editor, browser, browser]), settle: {}) { ["ok": true] }
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(
            result[FrontmostGuard.resultKey] as? String,
            "user_focus_changed: com.example.editor -> com.example.browser"
        )
    }

    func testTheResultIsUntouchedWhenFocusStays() throws {
        let result = try FrontmostGuard().run(read: { self.editor }, settle: {}) { ["ok": true] }
        XCTAssertNil(result[FrontmostGuard.resultKey])
    }

    func testAChangeThatAppearsOnlyAfterTheWaitSaysSo() throws {
        let result = try FrontmostGuard().run(read: reader([editor, editor, browser]), settle: {}) { [:] }
        XCTAssertEqual(
            result[FrontmostGuard.resultKey] as? String,
            "user_focus_changed: com.example.editor -> com.example.browser" + FrontmostGuard.withinSettleSuffix
        )
    }

    func testTwoInstancesOfOneAppAreToldApartByNameAndPid() {
        let first = FrontmostGuard.App(pid: 31, label: "com.example.editor", name: "Editor")
        let second = FrontmostGuard.App(pid: 32, label: "com.example.editor", name: "Editor")
        XCTAssertEqual(
            FrontmostGuard.change(before: first, after: second),
            "user_focus_changed: Editor (pid 31) -> Editor (pid 32)"
        )
    }

    func testAnActionThatThrowsWithoutAChangeIsNotWrapped() {
        struct Boom: Error {}
        XCTAssertThrowsError(try FrontmostGuard().run(read: { self.editor }, settle: {}) { throw Boom() }) { error in
            XCTAssertTrue(error is Boom)
        }
    }

    func testAnActionThatThrowsAfterTheAppChangedCarriesTheChangeInItsError() {
        let failure = HelperError(code: HelperError.accessibilityError, message: "failed")
        XCTAssertThrowsError(
            try FrontmostGuard().run(read: reader([editor, browser]), settle: {}) { throw failure }
        ) { error in
            let helperError = error as? HelperError
            XCTAssertEqual(helperError?.code, HelperError.accessibilityError)
            XCTAssertEqual(helperError?.message, "failed")
            XCTAssertEqual(
                helperError?.userFocusChanged,
                "user_focus_changed: com.example.editor -> com.example.browser"
            )
        }
    }

    func testACancelDuringTheSettleWaitKeepsTheResultOfTheFinishedAction() throws {
        let cancelled = HelperError(code: HelperError.abortedByUser, message: "stopped")
        let result = try FrontmostGuard().run(read: reader([editor, browser, browser]), settle: { throw cancelled }) {
            ["ok": true]
        }
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(
            result[FrontmostGuard.resultKey] as? String,
            "user_focus_changed: com.example.editor -> com.example.browser"
        )
    }

    func testAChangeSeenAtTheNextCommandsStartIsReportedOnce() throws {
        let guardian = FrontmostGuard()
        // The app was activated after the first command's settle wait.
        let first = try guardian.run(read: reader([editor, editor, editor]), settle: {}) { ["ok": 1] }
        XCTAssertNil(first[FrontmostGuard.resultKey])
        let second = try guardian.run(read: reader([browser, browser, browser]), settle: {}) { ["ok": 2] }
        XCTAssertEqual(
            second[FrontmostGuard.resultKey] as? String,
            "user_focus_changed: com.example.editor -> com.example.browser (since the previous action)"
        )
        let third = try guardian.run(read: reader([browser, browser, browser]), settle: {}) { ["ok": 3] }
        XCTAssertNil(third[FrontmostGuard.resultKey])
    }

    func testAnEarlierChangeAndAChangeDuringTheActionAreBothReported() throws {
        let guardian = FrontmostGuard()
        _ = try guardian.run(read: reader([editor, editor, editor]), settle: {}) { [:] }
        let result = try guardian.run(read: reader([browser, editor, editor]), settle: {}) { [:] }
        XCTAssertEqual(
            result[FrontmostGuard.resultKey] as? String,
            "user_focus_changed: com.example.editor -> com.example.browser (since the previous action)\nuser_focus_changed: com.example.browser -> com.example.editor"
        )
    }

    func testAThrowingActionDoesNotLeaveItsChangeForTheNextCommandToRepeat() throws {
        let guardian = FrontmostGuard()
        let failure = HelperError(code: HelperError.accessibilityError, message: "failed")
        XCTAssertThrowsError(try guardian.run(read: reader([editor, browser]), settle: {}) { throw failure })
        let next = try guardian.run(read: reader([browser, browser, browser]), settle: {}) { [:] }
        XCTAssertNil(next[FrontmostGuard.resultKey])
    }

    func testALauncherInFrontAfterTheActionGivesOnlyAnAuditDetail() throws {
        let result = try FrontmostGuard().run(read: reader([editor, nil, nil]), settle: {}) { ["ok": true] }
        XCTAssertNil(result[FrontmostGuard.resultKey])
        XCTAssertEqual(result[FrontmostGuard.detailKey] as? String, "front_app_unknown: com.example.editor -> none")
    }

    func testASwitchMadeWhileALauncherWasInFrontIsReportedFromTheLastKnownApp() throws {
        let guardian = FrontmostGuard()
        _ = try guardian.run(read: reader([editor, nil, nil]), settle: {}) { [:] }
        let next = try guardian.run(read: reader([browser, browser, browser]), settle: {}) { [:] }
        XCTAssertEqual(
            next[FrontmostGuard.resultKey] as? String,
            "user_focus_changed: com.example.editor -> com.example.browser (since the previous action)"
        )
        XCTAssertNil(next[FrontmostGuard.detailKey])
    }

    func testALauncherThatStaysInFrontAcrossActionsIsRecordedOnce() throws {
        let guardian = FrontmostGuard()
        let first = try guardian.run(read: reader([editor, nil, nil]), settle: {}) { [:] }
        XCTAssertNotNil(first[FrontmostGuard.detailKey])
        let second = try guardian.run(read: reader([nil, nil, nil]), settle: {}) { [:] }
        XCTAssertNil(second[FrontmostGuard.resultKey])
        XCTAssertNil(second[FrontmostGuard.detailKey])
        let third = try guardian.run(read: reader([editor, editor, editor]), settle: {}) { [:] }
        XCTAssertNil(third[FrontmostGuard.resultKey], "back to the same app the user had")
        XCTAssertEqual(
            third[FrontmostGuard.detailKey] as? String,
            "front_app_unknown: none -> com.example.editor (since the previous action)"
        )
    }

    func testAFailedActionCarriesAnUnknownFrontInItsErrorWithoutALine() {
        let failure = HelperError(code: HelperError.accessibilityError, message: "failed")
        XCTAssertThrowsError(try FrontmostGuard().run(read: reader([editor, nil]), settle: {}) { throw failure }) { error in
            let helperError = error as? HelperError
            XCTAssertEqual(helperError?.code, HelperError.accessibilityError)
            XCTAssertNil(helperError?.userFocusChanged)
            XCTAssertEqual(helperError?.focusWatchDetail, "front_app_unknown: com.example.editor -> none")
        }
    }

    func testOnlyRaiseIsRefusedAsASecondaryAction() {
        XCTAssertTrue(InputDriver.raisesWindow("AXRaise"))
        XCTAssertFalse(InputDriver.raisesWindow("AXShowMenu"))
        XCTAssertFalse(InputDriver.raisesWindow("AXPress"))
    }
}

final class FrontmostReadThreadTests: XCTestCase {
    func testTheFrontmostReadWorksFromTheMainThreadAndFromAnotherThread() {
        // A read from a background thread hops to the main thread; this test
        // runs on the main thread, so the hop must be skipped there instead
        // of waiting for itself.
        _ = FrontmostGuard.frontmost()
        let done = expectation(description: "read from a background thread")
        DispatchQueue.global().async {
            _ = FrontmostGuard.frontmost()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
