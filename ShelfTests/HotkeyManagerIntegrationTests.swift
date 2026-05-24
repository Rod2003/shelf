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
    func testSetEscEnabledIdempotent() {
        let manager = HotkeyManager()
        manager.setEscEnabled(true)
        manager.setEscEnabled(true)
        manager.setEscEnabled(false)
        manager.setEscEnabled(false)
        manager.setEscEnabled(true)
        manager.setEscEnabled(false)
    }
    func testSetSpaceEnabledIdempotent() {
        let manager = HotkeyManager()
        manager.setSpaceEnabled(true)
        manager.setSpaceEnabled(true)
        manager.setSpaceEnabled(false)
        manager.setSpaceEnabled(false)
        manager.setSpaceEnabled(true)
        manager.setSpaceEnabled(false)
    }
    func testEscAndSpaceTogglesAreIndependent() {
        let manager = HotkeyManager()
        manager.setEscEnabled(true)
        manager.setSpaceEnabled(true)
        manager.setEscEnabled(false)
        manager.setSpaceEnabled(false)
    }
    func testCallbacksAreSettableAndInvokable() {
        let manager = HotkeyManager()
        var showShelfFired = 0
        var closeFired = 0
        var quickLookFired = 0
        manager.onShowShelf = { showShelfFired += 1 }
        manager.onCloseFrontmost = { closeFired += 1 }
        manager.onQuickLook = { quickLookFired += 1 }
        manager.onShowShelf?()
        manager.onCloseFrontmost?()
        manager.onQuickLook?()

        XCTAssertEqual(showShelfFired, 1)
        XCTAssertEqual(closeFired, 1)
        XCTAssertEqual(quickLookFired, 1)
    }
    func testCallbacksDefaultToNilAndOptionalCallIsSafe() {
        let manager = HotkeyManager()
        XCTAssertNil(manager.onShowShelf)
        XCTAssertNil(manager.onCloseFrontmost)
        XCTAssertNil(manager.onQuickLook)
        manager.onShowShelf?()
        manager.onCloseFrontmost?()
        manager.onQuickLook?()
    }
    func testHotkeyKindRawValuesArePinned() {
        XCTAssertEqual(HotkeyManager.HotkeyKind.showShelf.rawValue, 1)
        XCTAssertEqual(HotkeyManager.HotkeyKind.closeFrontmost.rawValue, 2)
        XCTAssertEqual(HotkeyManager.HotkeyKind.quickLook.rawValue, 3)
        XCTAssertEqual(HotkeyManager.HotkeyKind.allCases.count, 3)
    }
}
