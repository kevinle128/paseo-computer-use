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

    /// The plugin reads the refused bundle id from this field, not from the
    /// message text.
    func testRefusalCarriesTheRefusedBundleId() {
        XCTAssertThrowsError(try list.check("  com.bitwarden.desktop ")) { error in
            let helperError = error as? HelperError
            XCTAssertEqual(helperError?.code, HelperError.appBlocked)
            XCTAssertEqual(helperError?.bundleId, "com.bitwarden.desktop")
        }
    }

    func testPrefixBlocksEveryIdThatStartsWithIt() {
        let webApps = AppBlockList(bundleIds: ["com.google.Chrome"], prefixes: [" com.google.Chrome.app. "])
        XCTAssertTrue(webApps.blocks("com.google.Chrome.app.abcdef"))
        XCTAssertTrue(webApps.blocks("COM.GOOGLE.CHROME.APP.ABCDEF"))
        XCTAssertTrue(webApps.blocks("com.google.Chrome"))
        XCTAssertFalse(webApps.blocks("com.google.Chrome.beta"))
        XCTAssertFalse(webApps.blocks("com.google.Chrome.app"))
        XCTAssertThrowsError(try webApps.check("com.google.Chrome.app.abcdef")) { error in
            XCTAssertEqual((error as? HelperError)?.bundleId, "com.google.Chrome.app.abcdef")
        }
        XCTAssertFalse(AppBlockList(bundleIds: [], prefixes: [" "]).blocks("com.apple.TextEdit"))
    }

    func testPrefixesAreOptionalInCommandParameters() throws {
        let withPrefixes = try AppBlockList(params: [
            "blockedBundleIds": ["com.bitwarden.desktop"],
            "blockedBundleIdPrefixes": ["com.apple.Safari.WebApp."],
        ])
        XCTAssertTrue(withPrefixes.blocks("com.apple.Safari.WebApp.0A1B2C3D"))
        XCTAssertEqual(
            withPrefixes,
            AppBlockList(bundleIds: ["com.bitwarden.desktop"], prefixes: ["com.apple.Safari.WebApp."])
        )
        XCTAssertFalse(try AppBlockList(params: ["blockedBundleIds": []]).blocks("com.apple.Safari.WebApp.0A1B2C3D"))
        XCTAssertThrowsError(try AppBlockList(params: ["blockedBundleIds": [], "blockedBundleIdPrefixes": "com."])) { error in
            XCTAssertEqual((error as? HelperError)?.code, HelperError.malformedRequest)
        }
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
    /// The partial name must match only Finder: a name such as "finde" also
    /// matches helper apps (Finder extensions, Quick Look), and the first
    /// match would then be an app that is not blocked.
    func testNameResolvingToBlockedBundleIdIsRefused() throws {
        let finderBlocked = AppBlockList(bundleIds: ["com.apple.finder"])
        let engine = AXEngine()
        let partialName = "apple.finder"
        let partialMatches = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated &&
                (($0.localizedName?.lowercased().contains(partialName) ?? false) ||
                    ($0.bundleIdentifier?.lowercased().contains(partialName) ?? false))
        }
        try XCTSkipUnless(
            partialMatches.map(\.bundleIdentifier) == ["com.apple.finder"],
            "Another running app also matches '\(partialName)'."
        )
        for name in ["Finder", partialName, "/System/Library/CoreServices/Finder.app"] {
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
