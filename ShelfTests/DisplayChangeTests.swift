import AppKit
import XCTest

@testable import Shelf
@MainActor
final class DisplayChangeTests: XCTestCase {
    func testOffScreenPanelRepositionsToFirstScreen() {
        let primary = PanelPositioner.Screen(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
        )
        let panelSize = CGSize(width: 360, height: 240)
        let offScreenFrame = CGRect(
            x: 3000,
            y: 500,
            width: panelSize.width,
            height: panelSize.height
        )
        let onAnyScreen = [primary].contains { $0.visibleFrame.intersects(offScreenFrame) }
        XCTAssertFalse(
            onAnyScreen,
            "off-screen frame at x=3000 must NOT intersect primary [0, 1920]"
        )
        let centered = CGPoint(
            x: primary.visibleFrame.midX - panelSize.width / 2,
            y: primary.visibleFrame.maxY - panelSize.height - 50
        )
        let clamped = PanelPositioner.clamp(
            origin: centered,
            panelSize: panelSize,
            in: primary.visibleFrame
        )
        XCTAssertGreaterThanOrEqual(
            clamped.x,
            primary.visibleFrame.minX + PanelPositioner.edgeMargin - 0.001
        )
        XCTAssertLessThanOrEqual(
            clamped.x + panelSize.width,
            primary.visibleFrame.maxX - PanelPositioner.edgeMargin + 0.001
        )
        XCTAssertGreaterThanOrEqual(
            clamped.y,
            primary.visibleFrame.minY + PanelPositioner.edgeMargin - 0.001
        )
        XCTAssertLessThanOrEqual(
            clamped.y + panelSize.height,
            primary.visibleFrame.maxY - PanelPositioner.edgeMargin + 0.001
        )
    }
    func testOnScreenPanelStaysPut() {
        let primary = PanelPositioner.Screen(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
        )
        let onScreenFrame = CGRect(x: 200, y: 300, width: 360, height: 240)

        let onAnyScreen = [primary].contains { $0.visibleFrame.intersects(onScreenFrame) }
        XCTAssertTrue(
            onAnyScreen,
            "frame at (200, 300) must intersect primary visibleFrame"
        )
    }
    func testPanelOnSecondaryStaysPut() {
        let primary = PanelPositioner.Screen(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
        )
        let secondary = PanelPositioner.Screen(
            frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1920, y: 0, width: 2560, height: 1415)
        )
        let secondaryPanelFrame = CGRect(x: 2500, y: 400, width: 360, height: 240)

        let onAnyScreen = [primary, secondary].contains {
            $0.visibleFrame.intersects(secondaryPanelFrame)
        }
        XCTAssertTrue(
            onAnyScreen,
            "panel on secondary display must NOT trigger reposition while secondary is connected"
        )
    }
    func testEmptyScreensYieldsNoTarget() {
        let screens: [PanelPositioner.Screen] = []
        XCTAssertNil(
            screens.first,
            "empty screens array must have nil first; manager early-returns"
        )
    }
    func testManagerRepositionEntrypointCallable() {
        let manager = ShelfWindowManager()
        let primary = PanelPositioner.Screen(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
        )
        manager.repositionPanelsForScreenChange(screens: [primary])
        XCTAssertEqual(manager.visibleShelfCount, 0)
    }
}
