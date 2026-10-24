import Foundation
import XCTest
@testable import PaseoComputerUseCore

final class CommandCancellationTests: XCTestCase {
    func testCancelStopsALongSleepFromAnotherThreadQuickly() {
        let token = CommandCancellation()
        let finished = expectation(description: "sleep returned")
        var thrown: HelperError?
        var elapsed: TimeInterval = 0

        let worker = Thread {
            let start = Date()
            do {
                // Two seconds, like a long type_text.
                try CommandCancellation.run(with: token) {
                    try CommandCancellation.sleepCurrent(micros: 2_000_000)
                }
            } catch let error as HelperError {
                thrown = error
            } catch {}
            elapsed = Date().timeIntervalSince(start)
            finished.fulfill()
        }
        worker.start()

        Thread.sleep(forTimeInterval: 0.05)
        token.cancel()
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(thrown?.code, HelperError.abortedByUser)
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testAlreadyCancelledTokenRefusesToStart() {
        let token = CommandCancellation()
        token.cancel()
        XCTAssertThrowsError(try token.check()) { error in
            XCTAssertEqual((error as? HelperError)?.code, HelperError.abortedByUser)
        }
    }

    func testCodeWithoutATokenIsNeverCancelled() throws {
        XCTAssertNil(CommandCancellation.current)
        try CommandCancellation.checkCurrent()
        try CommandCancellation.sleepCurrent(micros: 1_000)
    }

    func testTheCurrentTokenIsScopedToTheRunCall() throws {
        let token = CommandCancellation()
        try CommandCancellation.run(with: token) {
            XCTAssertTrue(CommandCancellation.current === token)
        }
        XCTAssertNil(CommandCancellation.current)
    }
}
