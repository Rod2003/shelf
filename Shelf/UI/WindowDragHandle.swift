import AppKit
import SwiftUI
public struct WindowDragHandle: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        DragHandleNSView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
private final class DragHandleNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 {
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}
