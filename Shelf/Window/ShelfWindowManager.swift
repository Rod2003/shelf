import AppKit
import OSLog
import ShelfCore

@MainActor
public final class ShelfWindowManager: NSObject, ShelfWindowControllerDelegate {
    public static let cascadeOffsetPx: CGFloat = 30

    private var controller: ShelfWindowController?
    private let log = Logger(subsystem: "dev.rod.shelf", category: "panel")

    public var onShelfClosed: (() -> Void)?

    public var onShelfBecameKey: (() -> Void)?

    public var onShelfResignedKey: (() -> Void)?

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public var visibleShelfCount: Int { controller == nil ? 0 : 1 }

    public func openShelf(
        _ shelfID: ShelfGroupID,
        contentView: NSView,
        baseOrigin: CGPoint
    ) {
        if let existing = controller {
            existing.show()
            log.debug("Re-showed existing panel id=\(existing.shelfID.rawValue.uuidString, privacy: .public)")
            return
        }
        let controller = ShelfWindowController(
            shelfID: shelfID,
            contentView: contentView,
            atOrigin: baseOrigin
        )
        controller.delegate = self
        self.controller = controller
        controller.show()
        log.info("Opened shelf panel id=\(shelfID.rawValue.uuidString, privacy: .public)")
    }

    public func closeShelf() {
        controller?.close()
    }

    public func closeAll() {
        controller?.close()
    }

    public func isShelfKey() -> Bool {
        controller?.panel.isKeyWindow == true
    }

    public func focusShelf() {
        controller?.show()
    }

    public func shelfController() -> ShelfWindowController? {
        controller
    }

    public func repositionPanelsForScreenChange(
        screens: [PanelPositioner.Screen]? = nil
    ) {
        let resolvedScreens = screens ?? PanelPositioner.liveScreens()
        guard let targetScreen = resolvedScreens.first else {
            log.error("repositionPanelsForScreenChange called with empty screens; skipping")
            return
        }
        guard let controller else { return }
        let panelFrame = controller.panel.frame
        let onAnyScreen = resolvedScreens.contains { $0.visibleFrame.intersects(panelFrame) }
        guard !onAnyScreen else { return }
        let panelSize = panelFrame.size
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
        log.info("Repositioned shelf id=\(controller.shelfID.rawValue.uuidString, privacy: .public) to (\(clamped.x, privacy: .public), \(clamped.y, privacy: .public))")
    }

    @objc private func handleScreenChange() {
        log.info("Screen parameters changed; repositioning panels")
        repositionPanelsForScreenChange()
    }

    public func shelfWindowDidClose(_ controller: ShelfWindowController) {
        self.controller = nil
        log.info("Shelf panel released id=\(controller.shelfID.rawValue.uuidString, privacy: .public)")
        onShelfClosed?()
    }

    public func shelfWindowDidBecomeKey(_ controller: ShelfWindowController) {
        onShelfBecameKey?()
    }

    public func shelfWindowDidResignKey(_ controller: ShelfWindowController) {
        onShelfResignedKey?()
    }
}
