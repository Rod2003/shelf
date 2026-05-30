import AppKit
import QuickLookUI
import OSLog
import ShelfCore
@MainActor
public final class QuickLookCoordinator: NSObject {
    public struct Preview {
        public let itemID: ItemID
        public let url: URL

        public init(itemID: ItemID, url: URL) {
            self.itemID = itemID
            self.url = url
        }
    }

    private final class PreviewItem: NSObject, QLPreviewItem {
        let itemID: ItemID
        let url: URL

        init(itemID: ItemID, url: URL) {
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
    private var sourceFramesByItemID: [ItemID: CGRect] = [:]
    private var heldResolutions: [BookmarkResolver.Resolution] = []
    private var observer: NSObjectProtocol?
    private var keyMonitor: Any?

    public var onDidClose: (() -> Void)?
    public var isVisible: Bool {
        !currentItems.isEmpty && QLPreviewPanel.shared()?.isVisible == true
    }

    public init(resolver: BookmarkResolver) {
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

    public func show(
        previews: [Preview],
        bookmarkResolutions: [BookmarkResolver.Resolution],
        sourceFramesByItemID: [ItemID: CGRect]
    ) {
        releaseHeldResolutions()

        guard !previews.isEmpty else {
            currentItems = []
            self.sourceFramesByItemID = [:]
            QLPreviewPanel.shared().close()
            return
        }

        currentItems = previews.map { PreviewItem(itemID: $0.itemID, url: $0.url) }
        self.sourceFramesByItemID = sourceFramesByItemID
        heldResolutions = bookmarkResolutions

        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.delegate = self
        installCloseObserverIfNeeded(panel: panel)
        installKeyMonitorIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        log.info("Quick Look opened with \(previews.count, privacy: .public) item(s) panelKey=\(panel.isKeyWindow, privacy: .public)")
    }

    @discardableResult
    public func closeIfVisible() -> Bool {
        let panel = QLPreviewPanel.shared()
        guard !currentItems.isEmpty, panel?.isVisible == true else {
            log.debug("Quick Look close skipped: visible=\(panel?.isVisible == true, privacy: .public) currentItemCount=\(self.currentItems.count, privacy: .public)")
            return false
        }
        log.info("Quick Look close requested panelKey=\(panel?.isKeyWindow == true, privacy: .public)")
        panel?.close()
        releaseHeldResolutions()
        currentItems = []
        sourceFramesByItemID = [:]
        log.info("Quick Look closed from Space toggle")
        return true
    }

    private func installCloseObserverIfNeeded(panel: QLPreviewPanel) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePanelDidClose()
            }
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.charactersIgnoringModifiers == " " else {
                return event
            }
            Task { @MainActor in
                self?.log.info("Quick Look Space intercepted by local monitor")
                self?.closeIfVisible()
            }
            return nil
        }
        log.debug("Quick Look local key monitor installed")
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
        log.debug("Quick Look local key monitor removed")
    }

    private func handlePanelDidClose() {
        log.info("Quick Look panel did close")
        removeKeyMonitor()
        releaseHeldResolutions()
        currentItems = []
        sourceFramesByItemID = [:]
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
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentItems.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentItems[index]
    }
}

extension QuickLookCoordinator: @preconcurrency QLPreviewPanelDelegate {
    public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown,
              event.charactersIgnoringModifiers == " " else {
            return false
        }
        log.info("Quick Look Space intercepted by preview panel delegate")
        closeIfVisible()
        return true
    }

    public func previewPanel(
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

    public func previewPanel(
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
