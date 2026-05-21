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
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
