// Shelf — WindowDragHandle
//
// A SwiftUI-friendly drag region that initiates a window-move when the user
// presses-and-drags inside it. We bridge through `NSViewRepresentable` because
// SwiftUI doesn't expose `NSWindow.performDrag(with:)`.
//
// The handle is fully transparent — visual treatment is the parent view's
// responsibility (e.g., a thin tinted strip, or nothing at all).
//
// Why this instead of `panel.isMovableByWindowBackground = true`?
// `isMovableByWindowBackground = true` causes AppKit to consume mouse-down
// events on the entire SwiftUI hosting view as window-drags, which steals
// `.onDrag` from individual shelf cells. By keeping
// `isMovableByWindowBackground = false` and using this targeted handle, the
// drag-out gesture on cells stays intact while the top strip still moves the
// window.
import AppKit
import SwiftUI

/// A transparent SwiftUI view whose AppKit backing initiates a window-drag
/// on `mouseDown`. Place it where you want the user to be able to grab the
/// window — typically a thin strip at the top of the panel content.
public struct WindowDragHandle: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        DragHandleNSView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}

/// AppKit-side implementation. `mouseDown(with:)` calls
/// `NSWindow.performDrag(with:)` which is the supported way to initiate a
/// programmatic window-drag — it follows the cursor until `mouseUp` and
/// respects all the standard window-snap / multi-display behavior.
private final class DragHandleNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
