// Shelf — AppKit cell wrapper for true MOVE-on-drag-out semantics.
//
// SwiftUI's `.onDrag` modifier returns an `NSItemProvider`, which is great
// for cross-platform parity but does NOT surface the `NSDragOperation`
// chosen by the receiver after the drop. Without that callback we can't
// distinguish:
//
//   • Receiver did `.move`  → we should delete the original file
//   • Receiver did `.copy`  → original stays untouched
//   • Drop was cancelled    → original stays, item stays in shelf
//
// This file replaces the SwiftUI `.onDrag` with an AppKit-driven drag
// initiated from a custom `NSView` that conforms to `NSDraggingSource` and
// `NSFilePromiseProviderDelegate`. The `draggingSession(_:endedAt:operation:)`
// callback gives us the receiver's chosen operation, which `AppCoordinator`
// uses to decide whether to delete the original.
//
// Tap detection: because the wrapper consumes `mouseDown(with:)` to start
// tracking for a potential drag, SwiftUI gestures inside the hosted cell
// (e.g., `.onTapGesture`) never fire. Tap-to-select is therefore exposed as
// the `onTap` callback the wrapper invokes from `mouseUp` when no drag was
// started. `.onHover` keeps working because hover events go through
// `NSView.mouseEntered/mouseExited` which we don't intercept.
import AppKit
import OSLog
import ShelfCore
import SwiftUI
import UniformTypeIdentifiers

/// Reported back to the App Coordinator when a drag-out gesture ends.
///
/// `promiseAttempted` and `promiseSucceeded` together let the coordinator
/// distinguish the three drag-resolution paths:
///
/// 1. **File-promise path** (Finder, some sandboxed apps) — the receiver
///    reads `kPasteboardTypeFilePromiseContent` from the pasteboard and
///    AppKit calls back into `writePromiseTo`. We set
///    `promiseAttempted=true` on entry; `promiseSucceeded=true` after a
///    completed copy. The MOVE semantic deletion is gated on success.
/// 2. **`.fileURL` path** (browsers, Slack, web upload zones, anything
///    that doesn't speak the file-promise protocol) — the receiver reads
///    the URL directly and copies/uploads on its own. `writePromiseTo` is
///    never invoked, so `promiseAttempted=false`. We treat the drag as
///    successful (the bytes have left for the destination) and proceed
///    with MOVE deletion.
/// 3. **Cancelled** — `operation == []`. Item stays in shelf.
///
/// The coordinator must preserve the original ONLY when
/// `promiseAttempted && !promiseSucceeded` — the safety net for an
/// in-flight file-promise write that threw. Other cases delete to honor
/// Shelf's "drag-out always moves" semantic.
public struct DragOutResult: Sendable {
    public let itemID: ItemID
    public let operation: NSDragOperation
    public let promiseSucceeded: Bool
    public let promiseAttempted: Bool

    public init(
        itemID: ItemID,
        operation: NSDragOperation,
        promiseSucceeded: Bool,
        promiseAttempted: Bool
    ) {
        self.itemID = itemID
        self.operation = operation
        self.promiseSucceeded = promiseSucceeded
        self.promiseAttempted = promiseAttempted
    }
}

/// `NSFilePromiseProvider` subclass that ALSO writes the resolved
/// `.fileURL` (`public.file-url`) to the pasteboard.
///
/// Without this, only file-promise-aware destinations (Finder, a handful
/// of native apps) can receive the file. Browsers, chat apps (Slack /
/// Discord / Messages), and most web upload zones read `.fileURL`
/// exclusively and ignore promises — drag-out into those destinations
/// silently does nothing.
///
/// The provider still vends the file-promise types via `super`, so when
/// a destination accepts BOTH types (e.g., Finder), the system picks
/// whichever it prefers. Empirically, Finder uses the promise (and our
/// `writePromiseTo` runs); browsers use `.fileURL` (and our promise is
/// never invoked).
///
/// CRITICAL — purely behavioral subclass; no stored Swift properties.
///
/// During cross-process drag (shelf → another app), AppKit clones the
/// pasteboard writer through the Objective-C runtime via
/// `[[Class alloc] init]`. That path bypasses any Swift-only designated
/// initializer we'd add, traps with "unimplemented initializer 'init()'",
/// and crashes the app on every drop. We instead piggyback on the
/// inherited `userInfo` property (an `NSDictionary` that participates in
/// the ObjC clone correctly) to carry the file-URL string, and override
/// only behavior — never state. The configuring call site sets
/// `fileURLString` inside `userInfo` alongside `kind`/`record`/etc.
fileprivate final class FilePromiseProviderWithURL: NSFilePromiseProvider {
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if hasFileURLString { types.append(.fileURL) }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL, let urlString = fileURLString {
            return urlString
        }
        return super.pasteboardPropertyList(forType: type)
    }

    private var hasFileURLString: Bool {
        guard let s = fileURLString else { return false }
        return !s.isEmpty
    }

    private var fileURLString: String? {
        (userInfo as? [String: Any])?["fileURLString"] as? String
    }
}

/// Thread-safe success flag shared between the off-main `writePromiseTo`
/// callback and the @MainActor `draggingSession(_:endedAt:operation:)`
/// callback. The drag-source NSView holds one and resets it at the start
/// of every drag session.
///
/// Also owns the single shared `OperationQueue` returned from
/// `operationQueue(for:)` — sharing the queue across all promise calls
/// from a given cell is what lets `endedAt` block on
/// `waitUntilAllOperationsAreFinished()` to close a race condition
/// where AppKit fires `endedAt` on the MainActor before the off-main
/// `writePromiseTo` finishes its copy. Without that wait, the success
/// flag is read prematurely and `.move` drag-outs leave the original
/// file in place.
fileprivate final class PromiseOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _succeeded: Bool = false
    private var _attempted: Bool = false

    /// Shared queue for `writePromiseTo` calls within this cell's drag
    /// session. Returned verbatim from `operationQueue(for:)` so we can
    /// `waitUntilAllOperationsAreFinished()` on it from `endedAt`.
    /// `OperationQueue` is documented thread-safe; the `@unchecked
    /// Sendable` on this wrapper covers it.
    let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _succeeded = false
        _attempted = false
    }

    /// Marked from `writePromiseTo` on entry. Lets `endedAt` distinguish
    /// "destination invoked the promise but it failed" (preserve original)
    /// from "destination read `.fileURL` directly and never asked us"
    /// (delete original — Shelf's MOVE semantic).
    func markAttempted() {
        lock.lock(); _attempted = true; lock.unlock()
    }

    func markSucceeded() {
        lock.lock(); _succeeded = true; lock.unlock()
    }

    var succeeded: Bool {
        lock.lock(); defer { lock.unlock() }
        return _succeeded
    }

    var attempted: Bool {
        lock.lock(); defer { lock.unlock() }
        return _attempted
    }
}

/// SwiftUI wrapper that hosts a cell's content inside an `NSView` capable
/// of initiating an AppKit drag-out via `NSFilePromiseProvider` and
/// reporting the chosen `NSDragOperation` back to the App Coordinator.
@MainActor
public struct DragOutCellWrapper<Content: View>: NSViewRepresentable {
    let item: ShelfItem
    let onTap: () -> Void
    let onDragEnded: (DragOutResult) -> Void
    let content: Content

    public init(
        item: ShelfItem,
        onTap: @escaping () -> Void,
        onDragEnded: @escaping (DragOutResult) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.item = item
        self.onTap = onTap
        self.onDragEnded = onDragEnded
        self.content = content()
    }

    public func makeNSView(context: Context) -> DragOutCellNSView {
        let view = DragOutCellNSView()
        view.item = item
        view.onTap = onTap
        view.onDragEnded = onDragEnded

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        view.hostingView = hosting

        return view
    }

    public func updateNSView(_ nsView: DragOutCellNSView, context: Context) {
        nsView.item = item
        nsView.onTap = onTap
        nsView.onDragEnded = onDragEnded
        // Update the hosted SwiftUI content. We rebound rootView so visual
        // state (selection tint, hover, thumbnail) refreshes on each render
        // pass.
        if let hosting = nsView.hostingView as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }

    /// Tell SwiftUI how big the cell wants to be so `LazyVGrid` can lay it
    /// out. Without this, NSViewRepresentable falls back to the wrapper's
    /// `intrinsicContentSize` (which is `NSView.noIntrinsicMetric` by
    /// default), and cells collapse to 0×0 inside the grid.
    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DragOutCellNSView,
        context: Context
    ) -> CGSize? {
        guard let hosting = nsView.hostingView else { return nil }
        // `fittingSize` resolves the SwiftUI content's preferred size via
        // Auto Layout. ShelfItemView has `.frame(width: 96)` so the width
        // is fixed; height comes from the VStack's intrinsic content.
        return hosting.fittingSize
    }
}

/// AppKit-side cell view. Manages tap-vs-drag detection on `mouseDown`,
/// initiates an `NSDraggingSession` with an `NSFilePromiseProvider` payload,
/// and forwards the receiver's chosen `NSDragOperation` to the coordinator.
@MainActor
public final class DragOutCellNSView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private static let log = Logger(subsystem: "dev.rod.shelf", category: "drag")
    private static let dragThreshold: CGFloat = 4.0

    var item: ShelfItem!
    var onTap: (() -> Void)?
    var onDragEnded: ((DragOutResult) -> Void)?
    weak var hostingView: NSView?

    /// Tracks whether the most recent drag's `writePromiseTo` callback
    /// actually completed the copy. Read on MainActor in `endedAt`,
    /// written from the off-main operation queue. `nonisolated` so the
    /// off-main callback can access it without an actor hop.
    nonisolated fileprivate let promiseOutcome = PromiseOutcome()

    private var dragStartPoint: NSPoint?
    private var dragStartEvent: NSEvent?
    private var didStartDrag: Bool = false

    /// Cell area opts out of `panel.isMovableByWindowBackground`'s window-
    /// drag, same as `NoWindowDragOverlay`. That overlay is therefore
    /// redundant once a cell is wrapped in this NSView, but keeping it in
    /// `ShelfItemView`'s background is harmless (both return `false`).
    public override var mouseDownCanMoveWindow: Bool { false }

    /// Propagate the SwiftUI hosted view's intrinsic content size up so
    /// SwiftUI can size the cell correctly inside `LazyVGrid`.
    public override var intrinsicContentSize: NSSize {
        guard let hosting = hostingView else { return super.intrinsicContentSize }
        let size = hosting.intrinsicContentSize
        if size.width >= 0 && size.height >= 0 {
            return size
        }
        return hosting.fittingSize
    }

    // MARK: Mouse handling — tap vs drag detection

    public override func mouseDown(with event: NSEvent) {
        dragStartPoint = event.locationInWindow
        dragStartEvent = event
        didStartDrag = false
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint, !didStartDrag else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        if hypot(dx, dy) > Self.dragThreshold {
            didStartDrag = true
            startDragSession(with: dragStartEvent ?? event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            dragStartPoint = nil
            dragStartEvent = nil
        }
        if !didStartDrag {
            onTap?()
        }
        didStartDrag = false
    }

    // MARK: Drag initiation

    private func startDragSession(with event: NSEvent) {
        // Reset the per-drag promise outcome before kicking off a new
        // session — `writePromiseTo` will mark it succeeded if/when it
        // actually completes the file copy.
        promiseOutcome.reset()

        let writer = makePasteboardWriter()
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        // Use a snapshot of the cell as the drag preview image. AppKit
        // otherwise renders an empty rect that confuses receivers about
        // what's being dragged.
        if let snapshot = snapshotImage() {
            draggingItem.setDraggingFrame(bounds, contents: snapshot)
        } else {
            draggingItem.draggingFrame = bounds
        }
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotImage() -> NSImage? {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makePasteboardWriter() -> NSPasteboardWriting {
        switch item.kind {
        case .fileBookmark(let record):
            let typeIdentifier = Self.utiForFile(originalPath: record.originalPath)
            // Resolve the bookmark NOW so we can put the real file URL
            // on the pasteboard alongside the file promise. Browsers,
            // chat apps, and web upload zones read `.fileURL` directly
            // and never invoke `writePromiseTo`; without this the drag
            // silently does nothing in those destinations.
            //
            // We deliberately don't pair `release(_:)` here — for the
            // unsandboxed v1 build `startAccessingSecurityScopedResource`
            // is a no-op, so the leaked access is also a no-op. Future
            // sandboxed builds will need explicit lifetime management
            // tied to the drag session (release in `endedAt`).
            let resolvedURL: URL?
            do {
                let resolution = try BookmarkResolver().resolve(record)
                resolvedURL = resolution.url
            } catch {
                Self.log.warning("Drag-start bookmark resolve failed for \(record.originalPath, privacy: .public): \(String(describing: error), privacy: .public). Falling back to file-promise-only drag.")
                resolvedURL = nil
            }

            let provider: NSFilePromiseProvider = (resolvedURL != nil)
                ? FilePromiseProviderWithURL(fileType: typeIdentifier, delegate: self)
                : NSFilePromiseProvider(fileType: typeIdentifier, delegate: self)
            // Pack everything the off-main delegate methods need into the
            // userInfo dict — `BookmarkRecord`, `ItemID`, the display
            // name, and (when resolved) the absolute file URL string are
            // all carried here. `userInfo` is the inherited
            // `NSFilePromiseProvider` property that survives ObjC
            // cross-process cloning of the writer; see the
            // `FilePromiseProviderWithURL` doc for why we route the URL
            // through here instead of via a Swift stored property.
            var info: [String: Any] = [
                "kind": "fileBookmark",
                "record": record,
                "displayName": item.displayName,
            ]
            if let url = resolvedURL {
                info["fileURLString"] = url.absoluteString
            }
            provider.userInfo = info
            return provider

        case .clipboardImage(let filename):
            // Clipboard images live at a known path under our App
            // Support tree. Same compatibility argument as
            // `.fileBookmark`: provide the URL on the pasteboard so
            // browsers and chat apps can pick it up directly without
            // needing the file-promise protocol.
            let resolvedURL: URL? = {
                guard let appSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else { return nil }
                let url = appSupport
                    .appendingPathComponent("Shelf", isDirectory: true)
                    .appendingPathComponent("clipboard-images", isDirectory: true)
                    .appendingPathComponent(filename)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }()

            let provider: NSFilePromiseProvider = (resolvedURL != nil)
                ? FilePromiseProviderWithURL(fileType: UTType.png.identifier, delegate: self)
                : NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: self)
            var info: [String: Any] = [
                "kind": "clipboardImage",
                "filename": filename,
            ]
            if let url = resolvedURL {
                info["fileURLString"] = url.absoluteString
            }
            provider.userInfo = info
            return provider

        case .webURL(let url):
            // Web URLs and text don't need a file promise — they're inline
            // data the receiver can paste immediately.
            let pbItem = NSPasteboardItem()
            pbItem.setString(url.absoluteString, forType: .URL)
            pbItem.setString(url.absoluteString, forType: .string)
            return pbItem

        case .text(let text):
            let pbItem = NSPasteboardItem()
            pbItem.setString(text, forType: .string)
            return pbItem
        }
    }

    nonisolated private static func utiForFile(originalPath: String) -> String {
        let ext = (originalPath as NSString).pathExtension
        if ext.isEmpty { return UTType.data.identifier }
        return UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
    }

    nonisolated private static func suggestedBaseName(from name: String) -> String {
        let stripped = (name as NSString).deletingPathExtension
        return stripped.isEmpty ? name : stripped
    }

    // MARK: NSDraggingSource

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Allow the receiver to choose move / copy / generic / link. Finder
        // defaults to .move for same-volume drops and .copy for cross-volume,
        // and respects modifier keys (Command = move, Option = copy).
        return [.move, .copy, .generic, .link]
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let item, let onDragEnded else { return }

        // CRITICAL — close the writePromiseTo race.
        //
        // `endedAt` fires on the MainActor as soon as AppKit considers
        // the drag session done (typically right after mouse-up). But
        // `writePromiseTo` runs on the operation queue we returned from
        // `operationQueue(for:)`, and AppKit invokes the two paths
        // concurrently. In testing, `endedAt` fires ~1ms after
        // `writePromiseTo` enters its closure — but the actual file
        // copy doesn't finish for another ~3ms. Reading
        // `promiseOutcome.succeeded` here without waiting yields
        // `false` even when the copy ultimately succeeds, which makes
        // the coordinator's data-loss safety net incorrectly preserve
        // the original on every successful `.move` drag-out.
        //
        // Blocking on the shared queue is bounded by the file copy
        // duration (typically tens of ms; longer for multi-GB media).
        // The trade-off — cell stays visible in the shelf for the
        // duration of the copy — is actually preferable UX: the user
        // sees the cell vanish exactly when the destination receives
        // the file, not before.
        //
        // Skip the wait for cancelled drops (`operation == []`) — there
        // is no promise to wait on, and we want the cell to clear
        // immediately so the shelf reflects intent.
        if !operation.isEmpty {
            promiseOutcome.queue.waitUntilAllOperationsAreFinished()
        }

        let succeeded = promiseOutcome.succeeded
        let attempted = promiseOutcome.attempted
        Self.log.info(
            "Drag-out ended id=\(item.id.rawValue.uuidString, privacy: .public) operation=\(operation.rawValue, privacy: .public) promiseAttempted=\(attempted, privacy: .public) promiseSucceeded=\(succeeded, privacy: .public)"
        )
        onDragEnded(DragOutResult(
            itemID: item.id,
            operation: operation,
            promiseSucceeded: succeeded,
            promiseAttempted: attempted
        ))
    }

    // MARK: NSFilePromiseProviderDelegate
    //
    // These methods are explicitly `nonisolated` because the system invokes
    // them on the operation queue we return from `operationQueue(for:)`.
    // They MUST NOT touch any main-actor state of `self`; everything they
    // need is in `provider.userInfo`.

    nonisolated public func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        guard let info = filePromiseProvider.userInfo as? [String: Any] else {
            return "Untitled"
        }
        // CRITICAL: NSFilePromiseProvider's `fileNameForType` expects the
        // FULL filename INCLUDING the extension. The system uses this
        // string verbatim to construct the destination URL. Returning
        // "foo" (no extension) makes the file land at "~/Downloads/foo"
        // with no extension, which looks like a missing-file bug to the
        // user. (NSItemProvider's `suggestedName` is the opposite — that
        // one wants the basename without extension. Different APIs.)
        if let displayName = info["displayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let filename = info["filename"] as? String, !filename.isEmpty {
            return filename
        }
        return "Untitled"
    }

    nonisolated public func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        // Return the shared per-cell queue so `endedAt` can wait on it
        // via `waitUntilAllOperationsAreFinished()`. Returning a fresh
        // queue here would defeat that wait — the queue we'd be waiting
        // on would always be empty, and writePromiseTo would run on a
        // different queue entirely.
        return promiseOutcome.queue
    }

    nonisolated public func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Mark BEFORE any guard returns. `endedAt` reads this to decide
        // whether the destination chose the file-promise path or the
        // `.fileURL` direct-read path; an early-failed guard still counts
        // as "attempted" so the data-loss safety net engages.
        self.promiseOutcome.markAttempted()

        guard
            let info = filePromiseProvider.userInfo as? [String: Any],
            let kind = info["kind"] as? String
        else {
            completionHandler(NSError(
                domain: "dev.rod.shelf.drag",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Promise has no item info"]
            ))
            return
        }

        switch kind {
        case "fileBookmark":
            guard let record = info["record"] as? BookmarkRecord else {
                Self.log.error("writePromiseTo: missing BookmarkRecord in userInfo")
                completionHandler(NSError(
                    domain: "dev.rod.shelf.drag",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Promise missing bookmark record"]
                ))
                return
            }
            Self.log.info("writePromiseTo: fileBookmark dest=\(url.path, privacy: .public)")
            let resolver = BookmarkResolver()
            do {
                let resolution = try resolver.resolve(record)
                defer { resolver.release(resolution.url) }
                Self.log.info("writePromiseTo: resolved source=\(resolution.url.path, privacy: .public)")
                try FileManager.default.copyItem(at: resolution.url, to: url)
                Self.log.info("writePromiseTo: copy complete")
                self.promiseOutcome.markSucceeded()
                completionHandler(nil)
            } catch {
                Self.log.error("writePromiseTo: copy failed: \(String(describing: error), privacy: .public)")
                completionHandler(error)
            }

        case "clipboardImage":
            guard let filename = info["filename"] as? String else {
                completionHandler(NSError(
                    domain: "dev.rod.shelf.drag",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Promise missing image filename"]
                ))
                return
            }
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                completionHandler(NSError(
                    domain: "dev.rod.shelf.drag",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Application Support directory unreachable"]
                ))
                return
            }
            let source = appSupport
                .appendingPathComponent("Shelf", isDirectory: true)
                .appendingPathComponent("clipboard-images", isDirectory: true)
                .appendingPathComponent(filename)
            Self.log.info("writePromiseTo: clipboardImage source=\(source.path, privacy: .public) dest=\(url.path, privacy: .public)")
            do {
                try FileManager.default.copyItem(at: source, to: url)
                self.promiseOutcome.markSucceeded()
                completionHandler(nil)
            } catch {
                Self.log.error("writePromiseTo: clipboard copy failed: \(String(describing: error), privacy: .public)")
                completionHandler(error)
            }

        default:
            completionHandler(NSError(
                domain: "dev.rod.shelf.drag",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Unknown promise kind"]
            ))
        }
    }
}
