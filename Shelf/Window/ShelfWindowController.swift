import AppKit
import OSLog
import QuartzCore
import QuickLookUI
import ShelfCore

@MainActor
final class ShelfKeyHandlingPanel: NSPanel {
    /// Return true to consume; false to let the responder chain handle it.
    var onKeyDown: ((NSEvent) -> Bool)?
    var onKeyUp: ((NSEvent) -> Bool)?
    weak var quickLookPanelHost: QuickLookPanelHosting?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if onKeyUp?(event) == true { return }
        super.keyUp(with: event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookPanelHost?.acceptsPreviewPanelControl() ?? false
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookPanelHost?.beginPreviewPanelControl()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookPanelHost?.endPreviewPanelControl()
    }
}

@MainActor
final class ShelfWindowController: NSObject, NSWindowDelegate {
    let shelfID: UUID
    let panel: ShelfKeyHandlingPanel
    var onDidClose: (() -> Void)?

    var onKeyDown: ((NSEvent) -> Bool)? {
        get { panel.onKeyDown }
        set { panel.onKeyDown = newValue }
    }

    var onKeyUp: ((NSEvent) -> Bool)? {
        get { panel.onKeyUp }
        set { panel.onKeyUp = newValue }
    }

    var quickLookPanelHost: QuickLookPanelHosting? {
        get { panel.quickLookPanelHost }
        set { panel.quickLookPanelHost = newValue }
    }

    private let log = Logger(subsystem: "dev.rod.shelf", category: "panel")

    init(
        shelfID: UUID,
        contentView: NSView,
        atOrigin: CGPoint,
        panelSize: CGSize = PanelPositioner.collapsedPanelSize
    ) {
        self.shelfID = shelfID

        let frame = NSRect(origin: atOrigin, size: panelSize)
        let panel = ShelfKeyHandlingPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
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
        panel.contentView = contentView
        Self.applyRoundedClearMask(to: contentView.layer)
        Self.applyRoundedClearMask(to: contentView.superview?.layer)

        self.panel = panel
        super.init()
        panel.delegate = self
    }

    func show() {
        panel.orderFrontRegardless()
        panel.makeKey()
        log.info("Shelf panel shown id=\(self.shelfID.uuidString, privacy: .public)")
    }

    func close() {
        panel.close()
        log.info("Shelf panel close requested id=\(self.shelfID.uuidString, privacy: .public)")
    }

    private static func applyRoundedClearMask(to layer: CALayer?) {
        guard let layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.cornerRadius = ShelfGlass.panelCornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }

    func setFrameSize(
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
        // Opt out of App Nap / background throttling for the duration of the
        // animation. Shelf is LSUIElement/.accessory driving a nonactivating
        // panel, so it's a prime throttling candidate when the system is busy
        // (e.g. screen recording), which visibly slows the frame animation.
        let activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Shelf panel resize animation"
        )
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.94, 0.36, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: {
            ProcessInfo.processInfo.endActivity(activityToken)
            completion?()
        })
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

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.onDidClose?()
        }
    }
}
