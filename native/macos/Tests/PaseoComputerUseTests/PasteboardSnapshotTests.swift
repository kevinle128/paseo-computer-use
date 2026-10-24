import AppKit
import XCTest
@testable import PaseoComputerUseCore

final class PasteboardSnapshotTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("paseo-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testRestoresEveryItemAndEveryType() {
        let first = NSPasteboardItem()
        first.setString("plain one", forType: .string)
        first.setData(Data("{\\rtf1 one}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("plain two", forType: .string)
        second.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pasteboard.writeObjects([first, second])

        let snapshot = PasteboardSnapshot.capture(pasteboard)
        XCTAssertEqual(snapshot.items.count, 2)

        pasteboard.clearContents()
        pasteboard.setString("pasted secret", forType: .string)
        snapshot.restore(to: pasteboard)

        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "plain one")
        XCTAssertEqual(items[0].data(forType: .rtf), Data("{\\rtf1 one}".utf8))
        XCTAssertEqual(items[1].string(forType: .string), "plain two")
        XCTAssertEqual(items[1].data(forType: .png), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(PasteboardSnapshot.capture(pasteboard), snapshot)
    }

    func testEmptyClipboardIsClearedAfterRestore() {
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        XCTAssertTrue(snapshot.items.isEmpty)

        pasteboard.setString("pasted secret", forType: .string)
        snapshot.restore(to: pasteboard)

        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
    }
}
