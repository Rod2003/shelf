import AppKit
import QuickLookUI
import OSLog
import ShelfCore
@MainActor
public final class QuickLookCoordinator: NSObject {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")
    private var currentURLs: [URL] = []

    public override init() {
        super.init()
    }
    public func show(urls: [URL]) {
        guard !urls.isEmpty else {
            QLPreviewPanel.shared().close()
            return
        }
        currentURLs = urls
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        log.info("Quick Look opened with \(urls.count, privacy: .public) item(s)")
    }
}

extension QuickLookCoordinator: QLPreviewPanelDataSource {
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURLs.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentURLs[index] as NSURL
    }
}

extension QuickLookCoordinator: QLPreviewPanelDelegate {}
