import AppKit
import QuickLookUI
import OSLog
import ShelfCore
@MainActor
public final class QuickLookCoordinator: NSObject {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")
    private let resolver: BookmarkResolver
    private var currentURLs: [URL] = []
    private var heldResolutions: [BookmarkResolver.Resolution] = []
    private var observer: NSObjectProtocol?

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
    }

    /// Shows bookmark-backed resolutions and plain file URLs in one Quick Look panel.
    /// Resolutions stay security-scoped until replaced or the panel closes.
    public func show(
        bookmarkResolutions: [BookmarkResolver.Resolution],
        unscopedURLs: [URL]
    ) {
        releaseHeldResolutions()

        let urls = bookmarkResolutions.map(\.url) + unscopedURLs
        guard !urls.isEmpty else {
            currentURLs = []
            QLPreviewPanel.shared().close()
            return
        }

        currentURLs = urls
        heldResolutions = bookmarkResolutions

        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.delegate = self
        installCloseObserverIfNeeded(panel: panel)
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        log.info("Quick Look opened with \(urls.count, privacy: .public) item(s)")
    }

    private func installCloseObserverIfNeeded(panel: QLPreviewPanel) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.releaseHeldResolutions()
                self?.currentURLs = []
            }
        }
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
        currentURLs.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentURLs[index] as NSURL
    }
}

extension QuickLookCoordinator: QLPreviewPanelDelegate {}
