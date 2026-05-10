// Shelf — Quick Look panel lifecycle coordinator (T19).
//
// Owns a single `QLPreviewPanel` shared instance and its data source /
// delegate wiring. Callers (the App Coordinator in T18, or the shelf
// content view via a binding) push the URLs they want previewed via
// `show(urls:)`; passing an empty array dismisses any open panel.
//
// Quick Look's panel is a singleton owned by AppKit, so this class does
// NOT retain it. It only retains the URLs currently being previewed so
// the data source can answer count/index queries. The panel asks us for
// items synchronously on the main thread, which is why the type is
// `@MainActor`.
//
// V1 scope:
// - File URLs only; non-file kinds (webURL, text, clipboardImage with no
//   on-disk backing) are filtered out by the call site before this
//   coordinator is invoked.
// - Default `QLPreviewPanelDelegate` behavior is sufficient (no custom
//   transition rects, no override of "should handle key down").
import AppKit
import QuickLookUI
import OSLog
import ShelfCore

/// Routes selected shelf items to the system Quick Look panel.
///
/// Lifetime: one instance per shelf window is fine; the underlying
/// `QLPreviewPanel.shared()` is process-wide, so concurrent shelves
/// will fight over its data source. V1 ships one shelf at a time, so
/// this is acceptable.
@MainActor
public final class QuickLookCoordinator: NSObject {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")
    private var currentURLs: [URL] = []

    public override init() {
        super.init()
    }

    /// Open Quick Look for the given URLs. Pass an empty array to dismiss
    /// any open panel (a no-op if none is showing).
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

extension QuickLookCoordinator: QLPreviewPanelDelegate {
    // Default delegate behavior is fine for v1. Hook points (transition
    // image, key-down forwarding) can be added when we need them.
}
