import AppKit
import Foundation
import OSLog
import ShelfCore

@MainActor
public final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {

    private let log = Logger(subsystem: "dev.rod.shelf", category: "drag")
    private let resolver: BookmarkResolver

    private let queue: OperationQueue

    public var pendingItems: [String: ShelfItem] = [:]

    public init(resolver: BookmarkResolver = BookmarkResolver()) {
        self.resolver = resolver
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        q.name = "dev.rod.shelf.file-promise"
        self.queue = q
        super.init()
    }

    public func clearPending(itemID: String) {
        pendingItems.removeValue(forKey: itemID)
    }

    public func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard
            let userInfo = filePromiseProvider.userInfo as? [String: Any],
            let id = userInfo["itemID"] as? String,
            let item = pendingItems[id]
        else {
            log.warning("fileNameForType: provider has no associated item; defaulting to \"Untitled\"")
            return "Untitled"
        }
        return item.displayName
    }

    nonisolated public func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        return queue
    }

    nonisolated public func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let userInfoSnapshot = filePromiseProvider.userInfo as? [String: Any]
        let itemID = userInfoSnapshot?["itemID"] as? String

        Task { @MainActor in
            guard
                let id = itemID,
                let item = self.pendingItems[id]
            else {
                let err = NSError(
                    domain: "dev.rod.shelf.drag",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Promise had no associated ShelfItem (itemID missing or unregistered)"]
                )
                self.log.error("writePromiseTo: missing pendingItems entry for id=\(itemID ?? "<nil>", privacy: .public)")
                completionHandler(err)
                return
            }
            let resolver = self.resolver
            // Finish writes on AppKit's promise queue before `endedAt`.
            self.queue.addOperation {
                do {
                    try Self.writeItem(item, to: url, resolver: resolver)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }

    nonisolated private static func writeItem(_ item: ShelfItem, to dest: URL, resolver: BookmarkResolver) throws {
        switch item.kind {
        case .fileBookmark(let record):
            let resolution = try resolver.resolve(record)
            defer { resolver.release(resolution.url) }
            try FileManager.default.copyItem(at: resolution.url, to: dest)

        case .clipboardImage(let filename):
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw NSError(
                    domain: "dev.rod.shelf.drag",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Application Support directory unavailable"]
                )
            }
            let source = appSupport
                .appendingPathComponent("Shelf", isDirectory: true)
                .appendingPathComponent("clipboard-images", isDirectory: true)
                .appendingPathComponent(filename)
            try FileManager.default.copyItem(at: source, to: dest)

        case .webURL, .text:
            throw NSError(
                domain: "dev.rod.shelf.drag",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Non-file ShelfItem kinds must use NSPasteboardItem, not NSFilePromiseProvider"]
            )
        }
    }
}
