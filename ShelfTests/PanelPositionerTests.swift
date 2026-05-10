import AppKit
import XCTest

@testable import Shelf

/// Deterministic, screen-environment-independent tests for
/// `PanelPositioner`. We construct synthetic `Screen` descriptors instead of
/// relying on the host's actual `NSScreen.screens`, so these pass in CI and
/// on any developer machine regardless of attached displays.
@MainActor
final class PanelPositionerTests: XCTestCase {

    /// Build a synthetic screen with a faux menu-bar inset on top, modelling
    /// macOS's typical visibleFrame relationship to frame.
    private func screen(
        frame: CGRect,
        visibleInsetTop: CGFloat = 25
    ) -> PanelPositioner.Screen {
        let visible = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: frame.height - visibleInsetTop
        )
        return PanelPositioner.Screen(frame: frame, visibleFrame: visible)
    }

    // MARK: AC-PO-01 — cursor at primary display origin clamps in

    func testCursorAtOriginClampsToVisibleFrameMargin() {
        let s = screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let result = PanelPositioner.computeOrigin(
            forCursor: CGPoint(x: 0, y: 0),
            panelSize: CGSize(width: 360, height: 240),
            screens: [s]
        )
        XCTAssertGreaterThanOrEqual(
            result.x,
            s.visibleFrame.minX + PanelPositioner.edgeMargin - 0.001
        )
        XCTAssertGreaterThanOrEqual(
            result.y,
            s.visibleFrame.minY + PanelPositioner.edgeMargin - 0.001
        )
        XCTAssertLessThanOrEqual(
            result.x + 360,
            s.visibleFrame.maxX - PanelPositioner.edgeMargin + 0.001
        )
        XCTAssertLessThanOrEqual(
            result.y + 240,
            s.visibleFrame.maxY - PanelPositioner.edgeMargin + 0.001
        )
    }

    // MARK: AC-PO-02 — cursor near right edge clamps inward

    func testCursorNearRightEdgeClampsInward() {
        let s = screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let result = PanelPositioner.computeOrigin(
            forCursor: CGPoint(x: 1900, y: 500),
            panelSize: CGSize(width: 360, height: 240),
            screens: [s]
        )
        XCTAssertLessThanOrEqual(
            result.x + 360,
            s.visibleFrame.maxX - PanelPositioner.edgeMargin + 0.001
        )
    }

    // MARK: AC-PO-03 — cursor near top of screen clamps below menu bar

    func testCursorNearTopClampsBelowMenuBar() {
        let s = screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // Cursor at top-of-screen y in AppKit (max y).
        let result = PanelPositioner.computeOrigin(
            forCursor: CGPoint(x: 960, y: 1080),
            panelSize: CGSize(width: 360, height: 240),
            screens: [s]
        )
        // Panel top must not exceed visibleFrame.maxY (menu bar zone excluded).
        XCTAssertLessThanOrEqual(
            result.y + 240,
            s.visibleFrame.maxY - PanelPositioner.edgeMargin + 0.001
        )
    }

    // MARK: AC-PO-04 — cursor on secondary display picks that display

    func testCursorOnSecondaryDisplayPicksThatDisplay() {
        let primary = screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let secondary = screen(frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
        let result = PanelPositioner.computeOrigin(
            forCursor: CGPoint(x: 3000, y: 500),
            panelSize: CGSize(width: 360, height: 240),
            screens: [primary, secondary]
        )
        XCTAssertGreaterThanOrEqual(
            result.x,
            secondary.visibleFrame.minX + PanelPositioner.edgeMargin - 0.001
        )
        // Sanity: didn't accidentally land on the primary screen.
        XCTAssertGreaterThanOrEqual(result.x, secondary.frame.minX - 0.001)
    }

    // MARK: AC-PO-05 — cursor off all screens falls back to first screen

    func testCursorOffAllScreensFallsBackToFirst() {
        let primary = screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let result = PanelPositioner.computeOrigin(
            forCursor: CGPoint(x: 9999, y: 9999),
            panelSize: CGSize(width: 360, height: 240),
            screens: [primary]
        )
        XCTAssertGreaterThanOrEqual(
            result.x,
            primary.visibleFrame.minX + PanelPositioner.edgeMargin - 0.001
        )
        XCTAssertLessThanOrEqual(
            result.x + 360,
            primary.visibleFrame.maxX - PanelPositioner.edgeMargin + 0.001
        )
        XCTAssertLessThanOrEqual(
            result.y + 240,
            primary.visibleFrame.maxY - PanelPositioner.edgeMargin + 0.001
        )
    }

    // MARK: AC-PO-06 — cascade for five simultaneous panels

    func testCascadeForFiveSimultaneous() {
        let base = CGPoint(x: 100, y: 500)
        let origins = (0..<5).map {
            PanelPositioner.cascadeOrigin(baseOrigin: base, existingCount: $0)
        }
        for (i, p) in origins.enumerated() {
            XCTAssertEqual(p.x, base.x + 30 * CGFloat(i), accuracy: 0.001)
            XCTAssertEqual(p.y, base.y - 30 * CGFloat(i), accuracy: 0.001)
        }
    }

    // MARK: Defensive — cascade wraps at 8 to avoid runaway off-screen marches

    func testCascadeWrapsAtEight() {
        let base = CGPoint(x: 100, y: 500)
        let origin8 = PanelPositioner.cascadeOrigin(baseOrigin: base, existingCount: 8)
        XCTAssertEqual(origin8.x, base.x, accuracy: 0.001)
        XCTAssertEqual(origin8.y, base.y, accuracy: 0.001)
    }

    // MARK: clamp(...) directly — sanity checks for the pure helper

    func testClampLeavesInteriorOriginUnchanged() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let result = PanelPositioner.clamp(
            origin: CGPoint(x: 100, y: 100),
            panelSize: CGSize(width: 360, height: 240),
            in: visible
        )
        XCTAssertEqual(result.x, 100, accuracy: 0.001)
        XCTAssertEqual(result.y, 100, accuracy: 0.001)
    }

    func testClampPullsOversizePanelToTopLeftWithMargin() {
        // Panel larger than the available area: clamp should resolve to
        // (minX + margin, minY + margin) since maxX/maxY become smaller than
        // those, and `min(origin, max)` then `max(min, ...)` collapses to min.
        let visible = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = PanelPositioner.clamp(
            origin: CGPoint(x: 500, y: 500),
            panelSize: CGSize(width: 360, height: 240),
            in: visible,
            edgeMargin: 8
        )
        XCTAssertEqual(result.x, 8, accuracy: 0.001)
        XCTAssertEqual(result.y, 8, accuracy: 0.001)
    }

    // MARK: containingScreen — multi-display dispatch

    func testContainingScreenPicksCorrectMonitor() {
        let primary = screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let secondary = screen(frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(
            PanelPositioner.containingScreen(of: CGPoint(x: 50, y: 50), screens: [primary, secondary]),
            primary
        )
        XCTAssertEqual(
            PanelPositioner.containingScreen(of: CGPoint(x: 3000, y: 50), screens: [primary, secondary]),
            secondary
        )
        XCTAssertNil(
            PanelPositioner.containingScreen(of: CGPoint(x: -50, y: -50), screens: [primary, secondary])
        )
    }
}
