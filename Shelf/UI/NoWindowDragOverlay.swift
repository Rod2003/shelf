// Shelf — NoWindowDragOverlay
//
// A SwiftUI-friendly transparent NSView whose `mouseDownCanMoveWindow`
// returns `false`, opting its bounds OUT of `panel.isMovableByWindowBackground`'s
// global "click-anywhere-to-drag" behavior.
//
// Why this exists:
//
//   With `panel.isMovableByWindowBackground = true`, AppKit treats every
//   click on a transparent NSView in the panel as a window-drag — including
//   clicks on SwiftUI cells, which means `.onDrag` never fires and you can't
//   drag files OUT of the shelf.
//
//   The fix is to make cells return `false` from `mouseDownCanMoveWindow`.
//   AppKit queries this property on the deepest hit-tested NSView for every
//   mouseDown. Inside a cell's area, this overlay is the deepest NSView, so
//   AppKit short-circuits the window-drag and hands the event up the
//   responder chain, where SwiftUI's gesture system picks up `.onDrag`.
//   Outside cells, the deepest hit is the outer NSHostingView (default
//   `mouseDownCanMoveWindow == true`), so the window drags as expected.
//
// Usage: place as `.background(NoWindowDragOverlay())` on each cell. The
// overlay is fully transparent and pass-through for everything except
// the window-drag opt-out.
import AppKit
import SwiftUI

/// SwiftUI wrapper that paints a transparent `NSView` in the cell area to
/// suppress AppKit's `isMovableByWindowBackground` click-to-drag behavior
/// in that region.
public struct NoWindowDragOverlay: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        NoWindowDragNSView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}

/// AppKit-side implementation. The `mouseDownCanMoveWindow` override is
/// the entire point of this class — every other property uses defaults.
/// Importantly, `mouseDown(with:)` is NOT overridden, so the event flows
/// up to NSHostingView's gesture recognizers (where SwiftUI `.onDrag`
/// engages on cells).
private final class NoWindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}
