import AppKit
import XCTest

@testable import Shelf

@MainActor
final class DisplayChangeTests: XCTestCase {
    func testRepositionIfOffScreenIsSafeWhenNoPanelIsOpen() {
        let manager = ShelfWindowManager()
        let primary = PanelPositioner.Screen(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
        )
        manager.repositionIfOffScreen(screens: [primary])
        XCTAssertFalse(manager.isVisible)
    }
}
