import AppKit
@objc(ShelfApplication)
@MainActor
final class ShelfApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
    }
}
