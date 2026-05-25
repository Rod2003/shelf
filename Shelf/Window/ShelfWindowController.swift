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

public final class ShelfKeyHandlingPanel: NSPanel {
    /// Return true to consume; false to let the responder chain handle it.
    public var onKeyDown: ((NSEvent) -> Bool)?

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
public final class ShelfWindowController: NSObject, NSWindowDelegate {
    public static let defaultPanelSize = CGSize(width: 180, height: 180)

    public let shelfID: ShelfGroupID
    public let panel: ShelfKeyHandlingPanel
    public weak var delegate: ShelfWindowControllerDelegate?

    public var onKeyDown: ((NSEvent) -> Bool)? {
        get { panel.onKeyDown }
        set { panel.onKeyDown = newValue }
    }

    private let log = Logger(subsystem: "dev.rod.shelf", category: "panel")

    public init(
        shelfID: ShelfGroupID,
        contentView: NSView,
        atOrigin: CGPoint,
        panelSize: CGSize = defaultPanelSize
    ) {
        self.shelfID = shelfID

        let frame = NSRect(origin: atOrigin, size: panelSize)
        let panel = ShelfKeyHandlingPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
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
        panel.isMovable = true
        // Drag only via explicit WindowDragHandle regions.
        panel.isMovableByWindowBackground = false

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
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

    public static let expansionDuration: TimeInterval = 0.32

    public func setFrameWidth(_ targetWidth: CGFloat, animated: Bool) {
        setFrameSize(CGSize(width: targetWidth, height: panel.frame.height), animated: animated)
    }

    public func setFrameSize(
        _ targetSize: CGSize,
        animated: Bool,
        duration: TimeInterval = 0.32,
        completion: (() -> Void)? = nil
    ) {
        guard targetSize.width > 0, targetSize.height > 0 else {
            completion?()
            return
        }
        let targetFrame = frame(for: targetSize)
        guard animated else {
            panel.setFrame(targetFrame, display: true, animate: false)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.94, 0.36, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: completion)
    }

    private func frame(for targetSize: CGSize) -> NSRect {
        var frame = panel.frame
        let oldMidX = frame.midX
        let oldMidY = frame.midY
        frame.size = targetSize
        frame.origin = CGPoint(
            x: oldMidX - targetSize.width / 2,
            y: oldMidY - targetSize.height / 2
        )

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
