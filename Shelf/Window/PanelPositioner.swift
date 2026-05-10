import AppKit
import CoreGraphics
import Foundation

/// Pure-function panel positioning. Accepts injectable screen frames so tests
/// don't need real `NSScreen` instances (which are environment-dependent and
/// hostile to deterministic XCTest runs).
///
/// Design notes:
/// - AppKit screen coordinates have origin at the bottom-left of the primary
///   display. `NSEvent.mouseLocation` is in this same coordinate space.
/// - The "anchor" places the cursor near the upper-left interior of the panel
///   (~30 px in), then `clamp(...)` pulls the rect back inside the cursor's
///   screen `visibleFrame` (which already excludes menu bar / Dock) minus an
///   `edgeMargin` so the panel never hugs the screen edge.
/// - `cascadeOffsetPx` matches `ShelfWindowManager.cascadeOffsetPx` (T11) so
///   the cascade visual is consistent regardless of which layer applies it.
@MainActor
public enum PanelPositioner {
    /// Minimum gap (in points) between the panel rect and the screen's
    /// `visibleFrame` edges. Picked to match the macOS HIG visual breathing
    /// room around floating utility windows.
    public static let edgeMargin: CGFloat = 8

    /// Default panel size used when callers don't supply one. Matches the
    /// initial NSPanel size in `ShelfWindowController` (T11).
    public static let defaultPanelSize = CGSize(width: 180, height: 180)

    /// Pixel offset applied per simultaneously-open panel for the visual
    /// cascade. Mirrored from `ShelfWindowManager.cascadeOffsetPx` (T11) so
    /// callers using either layer see identical spacing.
    public static let cascadeOffsetPx: CGFloat = 30

    /// Lightweight, value-type screen descriptor. Initialized from `NSScreen`
    /// via `init(_:)` for production use; constructed directly for tests.
    public struct Screen: Equatable {
        /// Full screen rect, including menu bar and Dock area.
        public let frame: CGRect
        /// Usable area, excluding menu bar / Dock (per AppKit's `visibleFrame`).
        public let visibleFrame: CGRect

        public init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }

        public init(_ ns: NSScreen) {
            self.init(frame: ns.frame, visibleFrame: ns.visibleFrame)
        }
    }

    /// Compute a panel origin for a fresh shelf at the given cursor.
    ///
    /// Strategy: place the panel so the cursor sits ~30 px from its top-left
    /// interior (a common Drag-and-Drop hotzone style); then clamp so the
    /// panel stays within the cursor's screen `visibleFrame` minus
    /// `edgeMargin`. If the cursor isn't on any screen (e.g. a stale value
    /// from a since-disconnected display), fall back to the first screen and
    /// place the panel near its top-left corner with margin.
    ///
    /// - Parameters:
    ///   - cursor: cursor location in AppKit screen coordinates
    ///     (origin bottom-left, y grows upward).
    ///   - panelSize: panel rect size (default `defaultPanelSize`).
    ///   - edgeMargin: minimum gap to screen visibleFrame edges
    ///     (default `edgeMargin`).
    ///   - screens: list of screen descriptors. In production, pass
    ///     `liveScreens()`; in tests, construct directly.
    /// - Returns: origin point (bottom-left of panel rect) clamped inside
    ///   the chosen screen's visibleFrame.
    public static func computeOrigin(
        forCursor cursor: CGPoint,
        panelSize: CGSize = defaultPanelSize,
        edgeMargin: CGFloat = edgeMargin,
        screens: [Screen]
    ) -> CGPoint {
        // Pick the screen the cursor is on, or fall back to the first screen
        // if the cursor doesn't intersect any (rare: stale cursor, headless).
        let resolvedScreen = containingScreen(of: cursor, screens: screens) ?? screens.first
        guard let screen = resolvedScreen else {
            // No screens at all — degenerate; return cursor unmodified. Should
            // not occur in practice (NSScreen.screens is always non-empty when
            // the app is running on a display).
            return cursor
        }
        // Anchor: cursor sits ~30 px inside the upper-left interior of the
        // panel. AppKit origin is bottom-left, so the panel's bottom-left y is
        // `cursor.y - panelSize.height + 30` to put the cursor ~30 px below
        // the panel's top edge.
        let desiredX = cursor.x - 30
        let desiredY = cursor.y - panelSize.height + 30
        return clamp(
            origin: CGPoint(x: desiredX, y: desiredY),
            panelSize: panelSize,
            in: screen.visibleFrame,
            edgeMargin: edgeMargin
        )
    }

    /// Apply cascade offset to a base origin, given the count of
    /// already-visible panels.
    ///
    /// Wraps back to the base origin every 8 panels — well beyond the 5-shelf
    /// cap (T11) — as a defensive guard so a runaway open-count never marches
    /// the cascade off-screen.
    ///
    /// - Parameters:
    ///   - baseOrigin: origin of the first panel in the cascade.
    ///   - existingCount: number of panels already on screen before this one.
    ///   - offsetPerPanel: pixel offset per cascade step
    ///     (default `cascadeOffsetPx`).
    /// - Returns: cascaded origin in AppKit screen coordinates.
    public static func cascadeOrigin(
        baseOrigin: CGPoint,
        existingCount: Int,
        offsetPerPanel: CGFloat = cascadeOffsetPx
    ) -> CGPoint {
        let n = existingCount % 8
        return CGPoint(
            x: baseOrigin.x + offsetPerPanel * CGFloat(n),
            y: baseOrigin.y - offsetPerPanel * CGFloat(n)
        )
    }

    /// Returns an origin guaranteed to keep `panelSize` inside `visibleFrame`
    /// minus `edgeMargin` on all four sides.
    ///
    /// If the panel is *bigger* than the available area (extremely small
    /// screen or oversized panel), prefer top-left alignment with margin —
    /// `min(...)` over `max(...)` collapses to the lower bound, which is what
    /// we want (panel anchored to top-left, overflowing toward bottom-right).
    public static func clamp(
        origin: CGPoint,
        panelSize: CGSize,
        in visibleFrame: CGRect,
        edgeMargin: CGFloat = edgeMargin
    ) -> CGPoint {
        let minX = visibleFrame.minX + edgeMargin
        let minY = visibleFrame.minY + edgeMargin
        let maxX = visibleFrame.maxX - edgeMargin - panelSize.width
        let maxY = visibleFrame.maxY - edgeMargin - panelSize.height
        let x = max(minX, min(origin.x, maxX))
        let y = max(minY, min(origin.y, maxY))
        return CGPoint(x: x, y: y)
    }

    /// First screen whose `frame` contains `point`, or nil if none does.
    public static func containingScreen(of point: CGPoint, screens: [Screen]) -> Screen? {
        screens.first { $0.frame.contains(point) }
    }

    /// Production helper: snapshot live `NSScreen.screens`. Marked
    /// `@MainActor` (via the enum-level annotation) since `NSScreen` access
    /// is main-thread-only.
    public static func liveScreens() -> [Screen] {
        NSScreen.screens.map(Screen.init)
    }

    /// Production helper: snapshot live cursor location.
    /// `NSEvent.mouseLocation` is in AppKit screen coordinates.
    public static func liveCursor() -> CGPoint {
        NSEvent.mouseLocation
    }
}
