import AppKit
import OSLog
import ShelfCore

@MainActor
public final class ShelfWindowManager: NSObject, ShelfWindowControllerDelegate {
    public static let cascadeOffsetPx: CGFloat = 30

    private var controllers: [ShelfGroupID: ShelfWindowController] = [:]
    private let log = Logger(subsystem: "dev.rod.shelf", category: "panel")

    public var onShelfClosed: ((ShelfGroupID) -> Void)?

    public var onShelfBecameKey: ((ShelfGroupID) -> Void)?

    public var onShelfResignedKey: ((ShelfGroupID) -> Void)?

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

    public var visibleShelfCount: Int { controllers.count }

    public func openShelf(_ shelfID: ShelfGroupID, contentView: NSView, baseOrigin: CGPoint) {
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

    public func closeShelf(_ shelfID: ShelfGroupID) {
        controllers[shelfID]?.close()
    }

    public func closeAll() {
        for controller in controllers.values {
            controller.close()
        }
    }

    public func currentlyKeyShelf() -> ShelfGroupID? {
        controllers.values.first { $0.panel.isKeyWindow }?.shelfID
    }

    public func openShelfIDs() -> [ShelfGroupID] {
        Array(controllers.keys)
    }

    public func focusShelf(_ shelfID: ShelfGroupID) {
        controllers[shelfID]?.show()
    }

    public func controller(for shelfID: ShelfGroupID) -> ShelfWindowController? {
        controllers[shelfID]
    }

    public func repositionPanelsForScreenChange(
        screens: [PanelPositioner.Screen]? = nil
    ) {
        let resolvedScreens = screens ?? PanelPositioner.liveScreens()
        guard let targetScreen = resolvedScreens.first else {
            log.error("repositionPanelsForScreenChange called with empty screens; skipping")
            return
        }
        for (id, controller) in controllers {
            let panelFrame = controller.panel.frame
            let onAnyScreen = resolvedScreens.contains { $0.visibleFrame.intersects(panelFrame) }
            guard !onAnyScreen else { continue }
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
            log.info("Repositioned shelf id=\(id.rawValue.uuidString, privacy: .public) to (\(clamped.x, privacy: .public), \(clamped.y, privacy: .public))")
        }
    }

    @objc private func handleScreenChange() {
        log.info("Screen parameters changed; repositioning panels")
        repositionPanelsForScreenChange()
    }

    private func computeCascadeOrigin(baseOrigin: CGPoint, existingCount: Int) -> CGPoint {
        let offset = CGFloat(existingCount) * Self.cascadeOffsetPx
        return CGPoint(x: baseOrigin.x + offset, y: baseOrigin.y - offset)
    }

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
