import AppKit

/// Custom NSApplication subclass referenced via Info.plist `NSPrincipalClass = ShelfApplication`.
/// The `@objc(ShelfApplication)` attribute exposes the class to the Objective-C runtime under
/// the unqualified name "ShelfApplication" (without the Swift module prefix), so AppKit can find
/// it when reading NSPrincipalClass from Info.plist.
///
/// Currently a marker class; the `sendEvent(_:)` override is reserved for future use
/// (per Spike A findings, drag detection uses NSPasteboard.changeCount + NSEvent.mouseLocation polling,
/// not sendEvent introspection — but the subclass remains in place for forward flexibility).
@objc(ShelfApplication)
@MainActor
final class ShelfApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
    }
}
