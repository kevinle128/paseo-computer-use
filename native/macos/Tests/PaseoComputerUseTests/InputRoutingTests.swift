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
}
