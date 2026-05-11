// `NSFilePromiseProvider` delegate.
//
// Implements the lazy / on-demand file delivery half of drag-OUT for
// `.fileBookmark` and `.clipboardImage` ShelfItems. Web-URL and plain-text
// items use `NSPasteboardItem` directly via `DragOutSource`; only file-style
// items need a promise provider.
//
// Concurrency model:
//   • The class is `@MainActor` because `pendingItems` is mutated from the
//     main thread (`DragOutSource.makePasteboardWriter(for:)` is called from
//     SwiftUI / AppKit drag-start code). Holding it on the main actor avoids
//     a separate lock for the dictionary.
//   • `operationQueue(for:)` is `nonisolated`. `OperationQueue` is documented
//     as thread-safe, so direct nonisolated access is correct without a
//     `MainActor.assumeIsolated` dance.
//   • `writePromiseTo` is `nonisolated`; AppKit invokes it on our returned
//     operation queue. We hop to the main actor briefly to read the
//     `pendingItems` snapshot, then dispatch the actual file copy back onto
//     the same operation queue so all I/O happens off-main.

import AppKit
import Foundation
import OSLog
import ShelfCore

/// Delegate for `NSFilePromiseProvider` instances Shelf produces during
/// drag-OUT.
///
/// The delegate is shared across all drag-out sessions for the lifetime of
/// the app; each `NSFilePromiseProvider` carries its `ShelfItem` indirection
/// through `provider.userInfo["itemID"]` (UUID string), with the actual
/// `ShelfItem` snapshot held in `pendingItems` on this delegate. Callers
/// (`DragOutSource`) MUST register the item in `pendingItems` BEFORE
/// handing the provider to the dragging session.
@MainActor
public final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {

    private let log = Logger(subsystem: "dev.rod.shelf", category: "drag")
    private let resolver: BookmarkResolver

    /// Serial operation queue used for on-demand promise fulfilment. A fresh
    /// queue per delegate instance — keeps drop semantics deterministic and
    /// avoids cross-talk between concurrent drag sessions.
    ///
    /// `OperationQueue` conforms to `Sendable`, so a plain `let` is reachable
    /// from the `nonisolated` `operationQueue(for:)` method without any
    /// `nonisolated(unsafe)` annotation.
    private let queue: OperationQueue

    /// Snapshot of items currently being promised, keyed by
    /// `provider.userInfo["itemID"]` (the UUID string of `ShelfItem.id`).
    ///
    /// `DragOutSource.makePasteboardWriter(for:)` populates this dictionary
    /// before returning the `NSFilePromiseProvider` to the dragging session.
    /// Entries are read on the main actor inside the `writePromiseTo`
    /// callback; entries are not removed automatically — growth is bounded
    /// by user drag activity within a session, which is acceptable.
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

    /// Remove a pending item from the registry. Optional cleanup hook for
    /// `DragOutSource` to invoke from `draggingSession(_:endedAt:operation:)`
    /// once a drag is done — keeps `pendingItems` from growing unbounded
    /// over a long session.
    public func clearPending(itemID: String) {
        pendingItems.removeValue(forKey: itemID)
    }

    // MARK: NSFilePromiseProviderDelegate

    /// Supply the destination filename. AppKit calls this on the main thread
    /// when a destination requests the promised file's name.
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

    /// Supply the operation queue AppKit uses to invoke `writePromiseTo`.
    /// Marked `nonisolated` because AppKit may call it off-main; backed by
    /// the `nonisolated(unsafe)` queue stored on this instance.
    nonisolated public func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        return queue
    }

    /// Fulfil a single file promise on `queue`. Invoked by AppKit on the
    /// queue returned from `operationQueue(for:)`.
    ///
    /// We briefly hop to the main actor to read the `pendingItems` snapshot
    /// (which is main-actor-isolated), then dispatch the actual file copy
    /// back onto the same operation queue so the I/O happens off-main and
    /// AppKit's expectation of "completion is invoked from the queue" is
    /// preserved.
    nonisolated public func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Capture only Sendable / value-typed material across the actor hop.
        // We lift the userInfo's itemID off the provider on the queue thread;
        // the provider object itself is not stored across the boundary.
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

    /// Static + `nonisolated` so it can be called from the operation queue's
    /// nonisolated `@Sendable` context. All inputs are Sendable / value-typed
    /// (`ShelfItem` is Sendable, `URL` is Sendable, and `BookmarkResolver`
    /// conforms to `Sendable` explicitly).
    nonisolated private static func writeItem(_ item: ShelfItem, to dest: URL, resolver: BookmarkResolver) throws {
        switch item.kind {
        case .fileBookmark(let record):
            let resolution = try resolver.resolve(record)
            defer { resolver.release(resolution.url) }
            // Use copyItem so we don't mutate the source. If the destination
            // already exists (rare — Finder normally ensures unique names),
            // we let `copyItem` surface the error to the completion handler.
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
