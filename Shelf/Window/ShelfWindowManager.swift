import AppKit
import OSLog
import ShelfCore

@MainActor
final class ShelfWindowManager {
    private var controller: ShelfWindowController?
    private var screenObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "dev.rod.shelf", category: "panel")

    var onShelfClosed: (() -> Void)?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenChange()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    var isVisible: Bool { controller != nil }

    var isKey: Bool { controller?.panel.isKeyWindow == true }

    func openShelf(
        _ shelfID: UUID,
        contentView: NSView,
        baseOrigin: CGPoint
    ) {
        if let existing = controller {
            existing.show()
            log.debug("Re-showed existing panel id=\(existing.shelfID.uuidString, privacy: .public)")
            return
        }
        let controller = ShelfWindowController(
            shelfID: shelfID,
            contentView: contentView,
            atOrigin: baseOrigin
        )
        controller.onDidClose = { [weak self] in
            self?.handleClosed()
        }
        self.controller = controller
        controller.show()
        log.info("Opened shelf panel id=\(shelfID.uuidString, privacy: .public)")
    }

    func closeShelf() {
        controller?.close()
    }

    func focusShelf() {
        controller?.show()
    }

    func shelfController() -> ShelfWindowController? {
        controller
    }

    func repositionIfOffScreen(
        screens: [PanelPositioner.Screen]? = nil
    ) {
        let resolvedScreens = screens ?? PanelPositioner.liveScreens()
        guard let targetScreen = resolvedScreens.first else {
            log.error("repositionIfOffScreen called with empty screens; skipping")
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
        log.info("Repositioned shelf id=\(controller.shelfID.uuidString, privacy: .public) to (\(clamped.x, privacy: .public), \(clamped.y, privacy: .public))")
    }

    private func handleScreenChange() {
        log.info("Screen parameters changed; repositioning panel")
        repositionIfOffScreen()
    }

    private func handleClosed() {
        guard let closed = controller else { return }
        controller = nil
        log.info("Shelf panel released id=\(closed.shelfID.uuidString, privacy: .public)")
        onShelfClosed?()
    }
}
