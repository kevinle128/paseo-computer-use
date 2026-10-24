import XCTest
@testable import PaseoComputerUseCore

final class AppBlockListTests: XCTestCase {
    private let list = AppBlockList(bundleIds: ["com.bitwarden.desktop", "com.apple.Passwords", " com.example.Extra "])

    func testBlocksRawBundleIdIgnoringCaseAndSpaces() {
        XCTAssertTrue(list.blocks("com.bitwarden.desktop"))
        XCTAssertTrue(list.blocks("COM.APPLE.PASSWORDS"))
        XCTAssertTrue(list.blocks("  com.example.extra"))
        XCTAssertFalse(list.blocks("com.apple.TextEdit"))
    }

    func testCheckThrowsAppNotAllowed() {
        XCTAssertThrowsError(try list.check("com.apple.Passwords")) { error in
            XCTAssertEqual((error as? HelperError)?.code, HelperError.appBlocked)
        }
        XCTAssertNoThrow(try list.check("com.apple.TextEdit"))
    }

    func testNotRunningBlockedBundleIdIsRefusedBeforeResolution() {
        let engine = AXEngine()
        XCTAssertThrowsError(try engine.resolveApplication("com.bitwarden.desktop", blocking: list)) { error in
            XCTAssertEqual((error as? HelperError)?.code, HelperError.appBlocked)
        }
    }

    func testBlocksOnePasswordSevenAndSecurityAgentFromThePluginList() {
        // The ids the plugin sends for 1Password 7 and the system
        // authorization prompt owner.
        let pluginList = AppBlockList(bundleIds: ["com.agilebits.onepassword7", "com.apple.SecurityAgent"])
        let engine = AXEngine()
        for id in ["com.agilebits.onepassword7", "com.apple.SecurityAgent", "com.apple.securityagent"] {
            XCTAssertThrowsError(try engine.resolveApplication(id, blocking: pluginList)) { error in
                XCTAssertEqual((error as? HelperError)?.code, HelperError.appBlocked, id)
            }
        }
    }

    /// A display name or a partial name is not on the list itself; the
    /// helper must refuse it after it resolves to a blocked bundle id.
    /// Finder is always running, so it stands in for a password manager.
    func testNameResolvingToBlockedBundleIdIsRefused() {
        let finderBlocked = AppBlockList(bundleIds: ["com.apple.finder"])
        let engine = AXEngine()
        for name in ["Finder", "finde", "/System/Library/CoreServices/Finder.app"] {
            XCTAssertFalse(finderBlocked.blocks(name))
            XCTAssertThrowsError(try engine.resolveApplication(name, blocking: finderBlocked)) { error in
                XCTAssertEqual((error as? HelperError)?.code, HelperError.appBlocked, name)
            }
        }
    }

    /// The refusal comes before any accessibility read: without the
    /// Accessibility permission an AX read would fail with another code.
    func testAppStateOfBlockedAppIsRefusedBeforeAnyAccessibilityRead() {
        let finderBlocked = AppBlockList(bundleIds: ["com.apple.finder"])
        XCTAssertThrowsError(try AXEngine().captureAppState(appIdentifier: "Finder", blocking: finderBlocked)) { error in
            XCTAssertEqual((error as? HelperError)?.code, HelperError.appBlocked)
        }
    }

    func testCommandWithoutTheListIsRefused() {
        XCTAssertThrowsError(try AppBlockList(params: ["app": "TextEdit"])) { error in
            XCTAssertEqual((error as? HelperError)?.code, HelperError.malformedRequest)
        }
        XCTAssertEqual(
            try AppBlockList(params: ["blockedBundleIds": ["com.bitwarden.desktop"]]),
            AppBlockList(bundleIds: ["com.bitwarden.desktop"])
        )
    }

    func testBoundsRelativeToWindowOrigin() {
        let bounds = AXBoundsSnapshot(x: 310, y: 225, width: 80, height: 24)
        XCTAssertEqual(bounds.relative(to: CGPoint(x: 300, y: 200)), AXBoundsSnapshot(x: 10, y: 25, width: 80, height: 24))
    }
}
