import AppKit
import OSLog
import QuartzCore
import ShelfCore

@MainActor
public protocol ShelfWindowControllerDelegate: AnyObject {
    func shelfWindowDidClose(_ controller: ShelfWindowController)
    func shelfWindowDidBecomeKey(_ controller: ShelfWindowController)
    func shelfWindowDidResignKey(_ controller: ShelfWindowController)
}

@MainActor
public final class ShelfWindowController: NSObject, NSWindowDelegate {
    public static let defaultPanelSize = CGSize(width: 180, height: 180)

    public let shelfID: ShelfGroupID
    public let panel: NSPanel
    public weak var delegate: ShelfWindowControllerDelegate?

    private let log = Logger(subsystem: "dev.rod.shelf", category: "panel")

    public init(
        shelfID: ShelfGroupID,
        contentView: NSView,
        atOrigin: CGPoint,
        panelSize: CGSize = defaultPanelSize
    ) {
        self.shelfID = shelfID

        let frame = NSRect(origin: atOrigin, size: panelSize)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        // Keep false so SwiftUI taps make the nonactivating panel key.
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = contentView

        self.panel = panel
        super.init()
        panel.delegate = self
    }

    public func show() {
        panel.orderFrontRegardless()
        log.info("Shelf panel shown id=\(self.shelfID.rawValue.uuidString, privacy: .public)")
    }

    public func close() {
        panel.close()
        log.info("Shelf panel close requested id=\(self.shelfID.rawValue.uuidString, privacy: .public)")
    }

    public func setFrameWidth(_ targetWidth: CGFloat, animated: Bool) {
        setFrameSize(CGSize(width: targetWidth, height: panel.frame.height), animated: animated)
    }

    public func setFrameSize(_ targetSize: CGSize, animated: Bool, bouncy: Bool = false) {
        guard targetSize.width > 0, targetSize.height > 0 else { return }
        guard animated else {
            panel.setFrame(frame(for: targetSize), display: true, animate: false)
            return
        }
        guard bouncy else {
            panel.setFrame(frame(for: targetSize), display: true, animate: true)
            return
        }

        let currentSize = panel.frame.size
        let widthDirection: CGFloat = targetSize.width >= currentSize.width ? 1 : -1
        let heightDirection: CGFloat = targetSize.height >= currentSize.height ? 1 : -1
        let overshoot = CGSize(
            width: targetSize.width + widthDirection * min(14, max(6, abs(targetSize.width - currentSize.width) * 0.05)),
            height: targetSize.height + heightDirection * min(14, max(6, abs(targetSize.height - currentSize.height) * 0.05))
        )
        let overshootFrame = frame(for: overshoot)
        let targetFrame = frame(for: targetSize)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(overshootFrame, display: true)
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    private func frame(for targetSize: CGSize) -> NSRect {
        var frame = panel.frame
        let oldTopY = frame.maxY
        frame.size = targetSize
        frame.origin.y = oldTopY - frame.height

        if let screen = panel.screen ?? NSScreen.screens.first {
            let clamped = PanelPositioner.clamp(
                origin: frame.origin,
                panelSize: frame.size,
                in: screen.visibleFrame
            )
            frame.origin = clamped
        }

        return frame
    }

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
