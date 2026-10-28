import XCTest
@testable import PaseoComputerUseCore

final class CacheSlotsTests: XCTestCase {
    func testReplacingStoresTheValue() {
        var slots = CacheSlots<String>()
        slots.store("agent read", for: 10, replace: true)
        XCTAssertEqual(slots[10], "agent read")
    }

    func testAReadThatDoesNotReplaceKeepsTheAgentsCache() {
        var slots = CacheSlots<String>()
        slots.store("agent read", for: 10, replace: true)
        slots.store("internal read", for: 10, replace: false)
        XCTAssertEqual(slots[10], "agent read")
    }

    func testAReadThatDoesNotReplaceCreatesNothing() {
        var slots = CacheSlots<String>()
        slots.store("internal read", for: 10, replace: false)
        XCTAssertNil(slots[10])
    }

    func testAppsAreIndependent() {
        var slots = CacheSlots<String>()
        slots.store("a", for: 1, replace: true)
        slots.store("b", for: 2, replace: true)
        slots.store("c", for: 2, replace: false)
        XCTAssertEqual(slots[1], "a")
        XCTAssertEqual(slots[2], "b")
    }
}
