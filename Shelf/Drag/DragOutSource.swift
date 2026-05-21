import AppKit
import Foundation
import OSLog
import ShelfCore
import UniformTypeIdentifiers

@MainActor
public final class DragOutSource: NSObject, NSDraggingSource {

    private let log = Logger(subsystem: "dev.rod.shelf", category: "drag")
    private let promiseDelegate: FilePromiseDelegate

    public init(promiseDelegate: FilePromiseDelegate) {
        self.promiseDelegate = promiseDelegate
        super.init()
    }

    public override convenience init() {
        self.init(promiseDelegate: FilePromiseDelegate())
    }

    public func makePasteboardWriter(for item: ShelfItem) -> NSPasteboardWriting? {
        switch item.kind {
        case .fileBookmark, .clipboardImage:
            let fileType = uti(for: item) ?? UTType.data.identifier
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: promiseDelegate)
            let key = item.id.rawValue.uuidString
            provider.userInfo = ["itemID": key]
            promiseDelegate.pendingItems[key] = item
            log.debug("makePasteboardWriter: file promise for itemID=\(key, privacy: .public) fileType=\(fileType, privacy: .public)")
            return provider

        case .webURL(let url):
            let pb = NSPasteboardItem()
            pb.setString(url.absoluteString, forType: .URL)
            pb.setString(url.absoluteString, forType: .string)
            log.debug("makePasteboardWriter: webURL pasteboard item")
            return pb

        case .text(let text):
            let pb = NSPasteboardItem()
            pb.setString(text, forType: .string)
            log.debug("makePasteboardWriter: text pasteboard item (\(text.count, privacy: .public) chars)")
            return pb
        }
    }

    private func uti(for item: ShelfItem) -> String? {
        switch item.kind {
        case .fileBookmark:
            // Use `displayName`; `originalPath` does not survive persistence.
            let ext = (item.displayName as NSString).pathExtension
            if ext.isEmpty { return UTType.data.identifier }
            return UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
        case .clipboardImage:
            return UTType.png.identifier
        case .webURL, .text:
            return nil
        }
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return [.copy, .generic]
        case .withinApplication:
            return [.copy, .move, .generic]
        @unknown default:
            return [.copy]
        }
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        log.info("Drag-out session ended op=\(operation.rawValue, privacy: .public) at=(\(screenPoint.x, privacy: .public),\(screenPoint.y, privacy: .public))")
    }
}
