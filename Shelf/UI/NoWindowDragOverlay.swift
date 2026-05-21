import AppKit
import SwiftUI
public struct NoWindowDragOverlay: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        NoWindowDragNSView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
private final class NoWindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}
