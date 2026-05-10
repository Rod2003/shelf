import AppKit
import OSLog
import ShelfCore

/// Owns one `ShelfWindowController` per visible shelf, keyed by `ShelfID`.
///
/// Multiple shelves can be open simultaneously; each gets its own NSPanel.
/// Per Spike B's canonical retention requirement, controllers are held
/// strongly in a `[ShelfID: ShelfWindowController]` dictionary so ARC does
/// not deallocate them when their NSPanels close (`isReleasedWhenClosed =
/// false` is necessary but not sufficient — without our strong reference,
/// the controller plus panel would still be released).
///
/// This type is presentation-only. It does NOT instantiate `ShelfStore` or
/// any model layer; the caller (T18 `AppCoordinator`) supplies a fully-built
/// `NSView` for the panel content. This keeps T11 free of model-layer
/// dependencies and lets T12 evolve independently.
@MainActor
public final class ShelfWindowManager: NSObject, ShelfWindowControllerDelegate {
    /// Pixel offset applied per simultaneously-open panel for visual cascade.
    /// This value is shared between the manager (when stacking new panels) and
    /// any future PanelPositioner (T16) that needs to know about cascading.
    public static let cascadeOffsetPx: CGFloat = 30

    private var controllers: [ShelfID: ShelfWindowController] = [:]
    private let log = Logger(subsystem: "dev.rod.shelf", category: "panel")

    /// Fired after a panel closes and the controller has been removed from
    /// the manager's dictionary. Useful for the coordinator to drop any
    /// per-shelf state it was tracking (e.g. focus tracking, drag tracking).
    public var onShelfClosed: ((ShelfID) -> Void)?

    /// Fired when a shelf's panel becomes key. Coordinator uses this to know
    /// where paste/shake events should target.
    public var onShelfBecameKey: ((ShelfID) -> Void)?

    /// Fired when a shelf's panel resigns key. Coordinator may use this to
    /// pause per-panel timers or update menu bar state.
    public var onShelfResignedKey: ((ShelfID) -> Void)?

    public override init() {
        super.init()
        // AppKit posts `didChangeScreenParametersNotification` on the main
        // thread (see Apple docs on AppKit notifications), and this manager
        // is `@MainActor`-isolated, so the @objc selector dispatch to
        // `handleScreenChange` lands on the main thread without an actor hop.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        // Selector-based observers are auto-removed by NSNotificationCenter
        // on macOS 10.11+, but explicit removal keeps deinit semantics
        // unambiguous and is documented thread-safe.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Public API

    /// Number of currently-tracked panels (visible OR hidden-but-retained).
    public var visibleShelfCount: Int { controllers.count }

    /// Open or focus the panel for the given shelf.
    ///
    /// If a controller already exists for `shelfID`, it is re-shown (which is a
    /// no-op if the panel is already on screen — `orderFrontRegardless()` is
    /// idempotent for already-visible panels). Otherwise a new
    /// `ShelfWindowController` is constructed at a cascade-offset origin
    /// derived from `baseOrigin` and the count of panels already open.
    ///
    /// - Parameters:
    ///   - shelfID: identity of the shelf to open.
    ///   - contentView: NSView to install as the panel's contentView. Typically
    ///     an `NSHostingView` or a drag-receiving NSView wrapping one (T12/T13).
    ///   - baseOrigin: anchor point (screen coordinates) before cascade offset.
    ///     Computed by the caller via `PanelPositioner` (T16).
    public func openShelf(_ shelfID: ShelfID, contentView: NSView, baseOrigin: CGPoint) {
        if let existing = controllers[shelfID] {
            existing.show()
            log.debug("Re-showed existing panel id=\(shelfID.rawValue.uuidString, privacy: .public)")
            return
        }
        let cascade = computeCascadeOrigin(baseOrigin: baseOrigin, existingCount: controllers.count)
        let controller = ShelfWindowController(shelfID: shelfID, contentView: contentView, atOrigin: cascade)
        controller.delegate = self
        controllers[shelfID] = controller
        controller.show()
        log.info("Opened shelf panel id=\(shelfID.rawValue.uuidString, privacy: .public); total=\(self.controllers.count, privacy: .public)")
    }

    /// Close the panel for the given shelf if one is currently tracked.
    ///
    /// Removal from the dictionary happens in the `shelfWindowDidClose`
    /// delegate callback rather than synchronously here, because NSPanel close
    /// fires `windowWillClose` on the next runloop hop and we want a single
    /// codepath for both user-initiated (⌘W / red button) and programmatic
    /// closes.
    public func closeShelf(_ shelfID: ShelfID) {
        controllers[shelfID]?.close()
    }

    /// Close every tracked panel. After this returns, controllers will still
    /// be in the dictionary briefly until each NSPanel's `windowWillClose`
    /// notification arrives.
    public func closeAll() {
        for controller in controllers.values {
            controller.close()
        }
    }

    /// Return the `ShelfID` whose panel is currently key, or `nil` if none.
    /// Used by paste/shake handlers (T15+) to target the right shelf.
    public func currentlyKeyShelf() -> ShelfID? {
        controllers.values.first { $0.panel.isKeyWindow }?.shelfID
    }

    /// Identifiers of every shelf with a tracked (open) panel. Order is not
    /// guaranteed; callers that need a stable order must sort by a property
    /// of `Shelf` (typically `createdAt`).
    public func openShelfIDs() -> [ShelfID] {
        Array(controllers.keys)
    }

    /// Bring the panel for `shelfID` to the front and make it key. No-op if
    /// the shelf isn't currently tracked. Distinct from `openShelf(...)`
    /// because focusing assumes the content view already exists — callers
    /// that may need to (re)build content should use `openShelf(...)` instead.
    public func focusShelf(_ shelfID: ShelfID) {
        controllers[shelfID]?.show()
    }

    /// Test/diagnostic helper: peek at the controller for a given shelf.
    /// Returns nil if no panel is currently tracked.
    public func controller(for shelfID: ShelfID) -> ShelfWindowController? {
        controllers[shelfID]
    }

    // MARK: Display change handling

    /// Reposition any tracked panel whose current frame no longer intersects
    /// any visible screen. Off-screen panels are recentered horizontally on
    /// the first supplied screen (typically the primary), placed near the
    /// top of `visibleFrame`, then clamped via `PanelPositioner.clamp(...)`
    /// so the rect stays inside the screen with the standard edge margin.
    ///
    /// Public so XCTests can drive it directly without posting a real
    /// `NSApplication.didChangeScreenParametersNotification`. Pass `nil`
    /// (or omit) to use `PanelPositioner.liveScreens()` for production
    /// callers; pass an explicit `[Screen]` array from tests for
    /// determinism. The default cannot be `PanelPositioner.liveScreens()`
    /// directly because Swift evaluates default expressions in a
    /// non-isolated synchronous context, which would fail @MainActor
    /// isolation on `liveScreens()`.
    ///
    /// Per T20 scope: positions are NOT persisted to ShelfStore (positions
    /// are ephemeral; cursor decides at next open). Per-shelf "preferred
    /// screen" is also out of scope — repositioning is silent and uniform.
    public func repositionPanelsForScreenChange(
        screens: [PanelPositioner.Screen]? = nil
    ) {
        let resolvedScreens = screens ?? PanelPositioner.liveScreens()
        guard let targetScreen = resolvedScreens.first else {
            // Degenerate: no screens at all (e.g. all displays disconnected).
            // Nothing safe to do — leave panels where they are; the next
            // notification with a non-empty screen list will recover them.
            log.error("repositionPanelsForScreenChange called with empty screens; skipping")
            return
        }
        for (id, controller) in controllers {
            let panelFrame = controller.panel.frame
            let onAnyScreen = resolvedScreens.contains { $0.visibleFrame.intersects(panelFrame) }
            guard !onAnyScreen else { continue }
            let panelSize = panelFrame.size
            // Center horizontally on the target screen, place near the top of
            // visibleFrame with a 50 pt offset for a visually pleasing landing.
            let centeredOrigin = CGPoint(
                x: targetScreen.visibleFrame.midX - panelSize.width / 2,
                y: targetScreen.visibleFrame.maxY - panelSize.height - 50
            )
            let clamped = PanelPositioner.clamp(
                origin: centeredOrigin,
                panelSize: panelSize,
                in: targetScreen.visibleFrame
            )
            controller.panel.setFrameOrigin(clamped)
            log.info("Repositioned shelf id=\(id.rawValue.uuidString, privacy: .public) to (\(clamped.x, privacy: .public), \(clamped.y, privacy: .public))")
        }
    }

    // MARK: Selectors

    /// Notification handler — fires on the main thread when display
    /// arrangement changes (resolution/scaling change, monitor connect or
    /// disconnect, primary swap). Repositions any panels that the change
    /// would otherwise leave off-screen.
    @objc private func handleScreenChange() {
        log.info("Screen parameters changed; repositioning panels")
        repositionPanelsForScreenChange()
    }

    // MARK: Internal

    private func computeCascadeOrigin(baseOrigin: CGPoint, existingCount: Int) -> CGPoint {
        let offset = CGFloat(existingCount) * Self.cascadeOffsetPx
        // Cascade rightward and downward in AppKit's flipped-y coordinate space:
        // AppKit screen coordinates have origin at bottom-left, so subtracting from y
        // moves the next panel visually downward.
        return CGPoint(x: baseOrigin.x + offset, y: baseOrigin.y - offset)
    }

    // MARK: ShelfWindowControllerDelegate

    public func shelfWindowDidClose(_ controller: ShelfWindowController) {
        controllers[controller.shelfID] = nil
        log.info("Shelf panel released id=\(controller.shelfID.rawValue.uuidString, privacy: .public); remaining=\(self.controllers.count, privacy: .public)")
        onShelfClosed?(controller.shelfID)
    }

    public func shelfWindowDidBecomeKey(_ controller: ShelfWindowController) {
        onShelfBecameKey?(controller.shelfID)
    }

    public func shelfWindowDidResignKey(_ controller: ShelfWindowController) {
        onShelfResignedKey?(controller.shelfID)
    }
}
