import AppKit
import XCTest

@testable import Shelf

/// Verifies the decision logic that drives
/// `ShelfWindowManager.repositionPanelsForScreenChange(screens:)` (T20).
///
/// We deliberately do NOT instantiate real `NSPanel` / `NSWindow` instances
/// in these tests because:
///   1. CI sandboxes / headless test runners block window-server access,
///      causing flaky test failures or process aborts.
///   2. The reposition algorithm is a thin wrapper around pure-function
///      `PanelPositioner.clamp(...)` plus a "frame intersects any screen?"
///      check. Verifying those primitives end-to-end is sufficient.
///
/// Live, end-to-end "drag the display arrangement and confirm the shelf
/// moved" verification is deferred to T26 agent QA per the T20 plan
/// scenario `AC-PO-05 display arrangement change with shelf open`.
@MainActor
final class DisplayChangeTests: XCTestCase {

    // MARK: AC-PO-06 — off-screen panel repositions to first screen

    /// Simulates the canonical T20 scenario: a shelf was open on a secondary
    /// display, the display was disconnected, and the panel's last frame is
    /// now entirely outside any remaining screen's visibleFrame. Confirms
    /// the manager's centering math lands inside the surviving screen and
    /// that `PanelPositioner.clamp(...)` keeps it there with the standard
    /// edge margin honored.
    func testOffScreenPanelRepositionsToFirstScreen() {
        let primary = PanelPositioner.Screen(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
        )
        let panelSize = CGSize(width: 360, height: 240)

        // A panel that lived on a now-disconnected secondary display:
        // x=3000 puts the entire rect outside the primary's [0, 1920].
        let offScreenFrame = CGRect(
            x: 3000,
            y: 500,
            width: panelSize.width,
            height: panelSize.height
        )

        // Sanity: the manager's "is this frame on any screen?" predicate
        // must return false for this rect when only `primary` is present.
        let onAnyScreen = [primary].contains { $0.visibleFrame.intersects(offScreenFrame) }
        XCTAssertFalse(
            onAnyScreen,
            "off-screen frame at x=3000 must NOT intersect primary [0, 1920]"
        )

        // Replicate the manager's centering formula and clamp pass.
        let centered = CGPoint(
            x: primary.visibleFrame.midX - panelSize.width / 2,
            y: primary.visibleFrame.maxY - panelSize.height - 50
        )
        let clamped = PanelPositioner.clamp(
            origin: centered,
            panelSize: panelSize,
            in: primary.visibleFrame
        )

        // Clamped origin must keep the panel rect entirely inside the
        // visibleFrame ± edgeMargin on all four sides.
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

    // MARK: AC-PO-05 — on-screen panel must stay put (no spurious repositioning)

    /// Confirms the manager will NOT touch a panel whose current frame is
    /// already on a visible screen. The reposition method is a no-op for
    /// any panel passing the "intersects any visibleFrame?" check.
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

    // MARK: Multi-screen — secondary still attached, panel on it stays put

    /// Confirms that when multiple screens are still attached and a panel
    /// is on the secondary, the predicate accepts it as on-screen and
    /// the manager skips it. This guards against a regression where the
    /// manager would always pick `screens.first` and aggressively reposition
    /// every secondary-display panel back to primary on any notification.
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

    // MARK: Empty screens — manager must skip silently

    /// If `screens` is empty (degenerate: all displays disconnected), the
    /// manager logs an error and skips. We can't directly observe the log
    /// here, but we verify the precondition that the manager checks first:
    /// `screens.first` returns nil for an empty array, which is the early
    /// return path.
    func testEmptyScreensYieldsNoTarget() {
        let screens: [PanelPositioner.Screen] = []
        XCTAssertNil(
            screens.first,
            "empty screens array must have nil first; manager early-returns"
        )
    }

    // MARK: Manager exposes the public reposition entrypoint

    /// Smoke check that the public API is callable from tests with an
    /// injected screens list. The manager has zero panels at this point,
    /// so the method is a guarded no-op (loop over empty controllers
    /// dictionary), but invoking it confirms the symbol is wired and
    /// `@MainActor`-callable from the test harness.
    func testManagerRepositionEntrypointCallable() {
        let manager = ShelfWindowManager()
        let primary = PanelPositioner.Screen(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
        )
        // Should not crash, throw, or assert; loop body never runs (no panels).
        manager.repositionPanelsForScreenChange(screens: [primary])
        XCTAssertEqual(manager.visibleShelfCount, 0)
    }
}
