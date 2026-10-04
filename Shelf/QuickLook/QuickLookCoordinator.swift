import AppKit
import QuickLookUI
import OSLog
import ShelfCore

@MainActor
protocol QuickLookPanelHosting: AnyObject {
    func acceptsPreviewPanelControl() -> Bool
    func beginPreviewPanelControl()
    func endPreviewPanelControl()
}

@MainActor
final class QuickLookCoordinator: NSObject, QuickLookPanelHosting {
    struct Preview {
        let itemID: UUID
        let url: URL

        init(itemID: UUID, url: URL) {
            self.itemID = itemID
            self.url = url
        }
    }

    private final class PreviewItem: NSObject, QLPreviewItem {
        let itemID: UUID
        let url: URL

        init(itemID: UUID, url: URL) {
            self.itemID = itemID
            self.url = url
        }

        var previewItemURL: URL? {
            url
        }

        var previewItemTitle: String? {
            url.lastPathComponent
        }
    }

    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")
    private let resolver: BookmarkResolver
    private var currentItems: [PreviewItem] = []
    private var sourceFramesByItemID: [UUID: CGRect] = [:]
    private var heldResolutions: [BookmarkResolver.Resolution] = []
    private var observer: NSObjectProtocol?
    private var keyMonitor: Any?
    private var isPresenting = false
    private var spaceSession = QuickLookSpaceSession()

    var onDidClose: (() -> Void)?
    var onOpenRequested: (() -> Void)?
    var isVisible: Bool {
        isPresenting && !currentItems.isEmpty && QLPreviewPanel.shared()?.isVisible == true
    }

    init(resolver: BookmarkResolver) {
        self.resolver = resolver
        super.init()
    }

    deinit {
        for resolution in heldResolutions {
            resolver.release(resolution.url)
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    func show(
        previews: [Preview],
        bookmarkResolutions: [BookmarkResolver.Resolution],
        sourceFramesByItemID: [UUID: CGRect]
    ) {
        releaseHeldResolutions()

        guard !previews.isEmpty else {
            if isPresenting {
                closePanelAndReset()
            }
            return
        }

        currentItems = previews.map { PreviewItem(itemID: $0.itemID, url: $0.url) }
        self.sourceFramesByItemID = sourceFramesByItemID
        heldResolutions = bookmarkResolutions
        isPresenting = true

        guard let panel = QLPreviewPanel.shared() else {
            log.error("Quick Look panel is unavailable; aborting preview")
            closePanelAndReset()
            return
        }
        becomePreviewController(for: panel)
        installCloseObserverIfNeeded(panel: panel)
        installKeyMonitorIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        log.info("Quick Look opened with \(previews.count, privacy: .public) item(s) panelKey=\(panel.isKeyWindow, privacy: .public)")
    }

    @discardableResult
    func closeIfVisible() -> Bool {
        let panel = QLPreviewPanel.shared()
        guard isVisible else {
            log.debug("Quick Look close skipped: visible=\(panel?.isVisible == true, privacy: .public) currentItemCount=\(self.currentItems.count, privacy: .public)")
            return false
        }
        log.info("Quick Look close requested panelKey=\(panel?.isKeyWindow == true, privacy: .public)")
        panel?.close()
        finishClose()
        log.info("Quick Look closed from Space toggle")
        return true
    }

    func acceptsPreviewPanelControl() -> Bool {
        isPresenting && !currentItems.isEmpty
    }

    func beginPreviewPanelControl() {
        guard let panel = QLPreviewPanel.shared() else { return }
        becomePreviewController(for: panel)
    }

    func endPreviewPanelControl() {}

    private func installCloseObserverIfNeeded(panel: QLPreviewPanel) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishClose()
            }
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                self.handleMonitoredEvent(event)
            }
        }
        log.debug("Quick Look local key monitor installed")
    }

    @discardableResult
    func handleSpaceEvent(_ event: NSEvent) -> Bool {
        guard SpaceKey.isUnmodifiedSpace(event) else { return false }
        switch event.type {
        case .keyDown:
            handleSpaceKeyDown(event)
        case .keyUp:
            handleSpaceKeyUp(event)
        default:
            break
        }
        return true
    }

    private func handleSpaceKeyDown(_ event: NSEvent) {
        switch spaceSession.handleKeyDown(isRepeat: event.isARepeat, at: event.timestamp) {
        case .ignore:
            log.debug("Quick Look Space ignored (repeat or unreleased press)")
        case .toggle:
            if isVisible {
                _ = closeIfVisible()
            } else {
                onOpenRequested?()
                if isVisible {
                    spaceSession.markOpenedQuickLook()
                }
            }
        }
    }

    private func handleSpaceKeyUp(_ event: NSEvent) {
        switch spaceSession.handleKeyUp(at: event.timestamp) {
        case .ignore:
            break
        case .dismissPeek:
            log.info("Quick Look dismissed on Space release")
            _ = closeIfVisible()
        }
    }

    private func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        handleSpaceEvent(event) ? nil : event
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        self.keyMonitor = nil
        DispatchQueue.main.async {
            NSEvent.removeMonitor(keyMonitor)
        }
        log.debug("Quick Look local key monitor removed")
    }

    private func becomePreviewController(for panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    private func closePanelAndReset() {
        QLPreviewPanel.shared()?.close()
        finishClose()
    }

    private func finishClose() {
        let shouldNotifyClose = isPresenting
        isPresenting = false
        removeKeyMonitor()
        releaseHeldResolutions()
        currentItems = []
        sourceFramesByItemID = [:]
        guard shouldNotifyClose else { return }
        log.info("Quick Look panel did close")
        onDidClose?()
    }

    private func releaseHeldResolutions() {
        for resolution in heldResolutions {
            resolver.release(resolution.url)
        }
        heldResolutions = []
    }
}

extension QuickLookCoordinator: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentItems[index]
    }
}

extension QuickLookCoordinator: @preconcurrency QLPreviewPanelDelegate {
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        handleSpaceEvent(event)
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        sourceFrameOnScreenFor item: (any QLPreviewItem)!
    ) -> NSRect {
        guard
            let previewItem = item as? PreviewItem,
            let frame = sourceFramesByItemID[previewItem.itemID],
            !frame.isEmpty
        else {
            return .zero
        }
        return frame
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        transitionImageFor item: (any QLPreviewItem)!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        guard let previewItem = item as? PreviewItem else { return nil }
        let image = NSWorkspace.shared.icon(forFile: previewItem.url.path)
        if let contentRect {
            contentRect.pointee = NSRect(origin: .zero, size: image.size)
        }
        return image
    }
}
