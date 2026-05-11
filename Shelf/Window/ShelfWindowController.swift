import AppKit
import OSLog
import ShelfCore

/// Delegate protocol for `ShelfWindowController` lifecycle and key-state events.
///
/// Conformers receive callbacks when the underlying NSPanel closes or changes
/// key state. The window manager (`ShelfWindowManager`) is the canonical
/// conformer; it uses `shelfWindowDidClose` to remove the controller from its
/// strong-reference dictionary.
@MainActor
public protocol ShelfWindowControllerDelegate: AnyObject {
    func shelfWindowDidClose(_ controller: ShelfWindowController)
    func shelfWindowDidBecomeKey(_ controller: ShelfWindowController)
    func shelfWindowDidResignKey(_ controller: ShelfWindowController)
}

/// Owns a single NSPanel for a single `ShelfID`.
///
/// The panel is configured per the canonical Spike B configuration:
/// `.nonactivatingPanel + .titled + .resizable + .closable` style mask,
/// floating window level, full-screen-auxiliary + can-join-all-spaces collection
/// behavior. Combined with `NSApp.setActivationPolicy(.accessory)` set in
/// AppDelegate, this delivers a panel that floats above everything without
/// activating Shelf.
///
/// `becomesKeyOnlyIfNeeded` is set to `false` so that any click on the panel
/// transitions it to the key state. With `true`, AppKit only made the panel
/// key when a subview *needed* key input (e.g. a TextField); SwiftUI tap
/// gestures don't propagate that "need" upward, so the panel never became
/// key, `windowDidBecomeKey` never fired, and the AppCoordinator's
/// `setSpaceEnabled(true)` / `setEscEnabled(true)` gating never armed —
/// Space (Quick Look) and Esc (close) were silently dead. Pairing
/// `becomesKeyOnlyIfNeeded = false` with `.nonactivatingPanel` keeps focus
/// cooperative: the panel becomes key without activating the app, so Safari
/// (or whichever was frontmost) stays frontmost while the shelf takes input.
///
/// The supplied `contentView` is installed as `panel.contentView` directly.
/// Callers wrap their `NSHostingView` in a custom NSView at this level if
/// they wish to register for dragged types — the controller is agnostic to
/// that wrapping.
@MainActor
public final class ShelfWindowController: NSObject, NSWindowDelegate {
    public let shelfID: ShelfID
    public let panel: NSPanel
    public weak var delegate: ShelfWindowControllerDelegate?

    private let log = Logger(subsystem: "dev.rod.shelf", category: "panel")

    /// Initialize a panel for the given shelf at the supplied origin and size.
    ///
    /// - Parameters:
    ///   - shelfID: identity of the shelf this panel represents.
    ///   - contentView: NSView installed as `panel.contentView`. Typically an
    ///     `NSHostingView` or a custom NSView that wraps one.
    ///   - atOrigin: bottom-left point in screen coordinates for the panel's frame.
    ///   - panelSize: initial panel size. Defaults to 360x240. Per-shelf size
    ///     is not persisted; resize survives only as long as the panel
    ///     instance does (`isReleasedWhenClosed = false`).
    public init(
        shelfID: ShelfID,
        contentView: NSView,
        atOrigin: CGPoint,
        panelSize: CGSize = CGSize(width: 180, height: 180)
    ) {
        self.shelfID = shelfID

        let frame = NSRect(origin: atOrigin, size: panelSize)
        let panel = NSPanel(
            contentRect: frame,
            // Borderless panel: no title bar at all, so the close button sits
            // at literal y=0 of the panel and the SwiftUI content fills the
            // entire panel without any phantom title-bar offset. Window-drag
            // works via `isMovableByWindowBackground = true` (set below);
            // shadow + rounded corners are handled by `hasShadow = true` and
            // the wrapper NSVisualEffectView's `cornerRadius` respectively.
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Per Spike B canonical config — do not deviate without updating the spike.
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        // Must be `false` so SwiftUI taps transition the panel to key state,
        // which arms Esc/Space hotkeys via AppCoordinator. Pairs safely with
        // `.nonactivatingPanel` — Shelf still does not activate. See the
        // class docstring for the failure mode of the `true` setting.
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Whole-panel drag: clicking anywhere on the shelf moves it. Cells
        // opt out of this region-by-region by wrapping themselves in a
        // `NoWindowDragOverlay` (an NSView whose `mouseDownCanMoveWindow`
        // returns false). AppKit queries `mouseDownCanMoveWindow` on the
        // deepest hit-tested NSView per mouseDown, so cell areas correctly
        // route to SwiftUI's `.onDrag`, while empty areas drag the window.
        panel.isMovableByWindowBackground = true

        // Liquid Glass / translucent material: panel itself is transparent so
        // the NSVisualEffectView in ContentViewFactory shows through.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // No title bar in the styleMask, so no traffic-light buttons or
        // titlebar separator to hide. The standardWindowButton lookups are
        // omitted because they have no slots to occupy in a borderless panel.
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = contentView

        self.panel = panel
        super.init()
        panel.delegate = self
    }

    /// Show the panel without activating Shelf.
    ///
    /// Per Spike B: use `orderFrontRegardless()` for first-show, NOT
    /// `makeKeyAndOrderFront(_:)`. The latter activates the app even with
    /// `.nonactivatingPanel`. For user-gesture re-show after a hotkey, callers
    /// should use `panel.makeKeyAndOrderFront(nil)` directly on the public
    /// `panel` property — at that point activation is desired.
    public func show() {
        panel.orderFrontRegardless()
        log.info("Shelf panel shown id=\(self.shelfID.rawValue.uuidString, privacy: .public)")
    }

    /// Close the panel. Because `isReleasedWhenClosed = false`, the NSPanel
    /// instance survives and can be re-shown by re-calling `show()`. The
    /// controller's owner (the window manager) decides whether to drop its
    /// strong reference based on the `shelfWindowDidClose` delegate callback.
    public func close() {
        panel.close()
        log.info("Shelf panel close requested id=\(self.shelfID.rawValue.uuidString, privacy: .public)")
    }

    // MARK: NSWindowDelegate

    nonisolated public func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.delegate?.shelfWindowDidClose(self)
        }
    }

    nonisolated public func windowDidBecomeKey(_ notification: Notification) {
        Task { @MainActor in
            self.delegate?.shelfWindowDidBecomeKey(self)
        }
    }

    nonisolated public func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            self.delegate?.shelfWindowDidResignKey(self)
        }
    }
}
