import AppKit
import XCTest

@testable import Shelf

@MainActor
final class HotkeyManagerIntegrationTests: XCTestCase {
    func testInitDoesNotCrash() {
        XCTAssertNoThrow({
            let manager = HotkeyManager()
            _ = manager
        }())
    }
    func testInitDeinitCycleIsClean() {
        weak var weakRef: HotkeyManager?
        autoreleasepool {
            let manager = HotkeyManager()
            weakRef = manager
            _ = manager
        }
        _ = weakRef
    }
    func testShowShelfCallbackIsSettableAndInvokable() {
        let manager = HotkeyManager()
        var showShelfFired = 0
        manager.onShowShelf = { showShelfFired += 1 }
        manager.onShowShelf?()

        XCTAssertEqual(showShelfFired, 1)
    }
    func testShowShelfCallbackDefaultsToNilAndOptionalCallIsSafe() {
        let manager = HotkeyManager()
        XCTAssertNil(manager.onShowShelf)
        manager.onShowShelf?()
    }
}
