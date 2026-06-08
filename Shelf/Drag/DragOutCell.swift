import AppKit
import OSLog
import ShelfCore
import SwiftUI
import UniformTypeIdentifiers

/// Remove shelf entries only when `promiseAttempted && promiseSucceeded`.
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

public struct MultiDragOutResult: Sendable {
    public let outcomes: [PerItem]
    public let operation: NSDragOperation

    public struct PerItem: Sendable {
        public let itemID: ItemID
        public let promiseSucceeded: Bool
        public let promiseAttempted: Bool
    }

    public init(outcomes: [PerItem], operation: NSDragOperation) {
        self.outcomes = outcomes
        self.operation = operation
    }
}

fileprivate final class FilePromiseProviderWithURL: NSFilePromiseProvider {
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if isInternalShelfDrag { types.append(DragItemFactory.internalShelfDragType) }
        if hasFileURLString { types.append(.fileURL) }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == DragItemFactory.internalShelfDragType, isInternalShelfDrag {
            return "1"
        }
        if type == .fileURL, let urlString = fileURLString {
            return urlString
        }
        return super.pasteboardPropertyList(forType: type)
    }

    private var isInternalShelfDrag: Bool {
        (userInfo as? [String: Any])?["internalShelfDrag"] as? Bool == true
    }

    private var hasFileURLString: Bool {
        guard let s = fileURLString else { return false }
        return !s.isEmpty
    }

    private var fileURLString: String? {
        (userInfo as? [String: Any])?["fileURLString"] as? String
    }
}

fileprivate final class PromiseOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _succeeded: Bool = false
    private var _attempted: Bool = false

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

fileprivate final class MultiPromiseOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted: Set<String> = []
    private var succeeded: Set<String> = []
    private var itemIDs: [String] = []

    let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()

    func reset(itemIDs newIDs: [ItemID]) {
        lock.lock()
        attempted.removeAll()
        succeeded.removeAll()
        itemIDs = newIDs.map { $0.rawValue.uuidString }
        lock.unlock()
    }

    func markAttempted(_ id: String?) {
        guard let id else { return }
        lock.lock(); attempted.insert(id); lock.unlock()
    }

    func markSucceeded(_ id: String?) {
        guard let id else { return }
        lock.lock(); succeeded.insert(id); lock.unlock()
    }

    func snapshot() -> [MultiDragOutResult.PerItem] {
        lock.lock()
        let ids = itemIDs
        let attempted = attempted
        let succeeded = succeeded
        lock.unlock()
        return ids.compactMap { idString in
            guard let uuid = UUID(uuidString: idString) else { return nil }
            return MultiDragOutResult.PerItem(
                itemID: ItemID(rawValue: uuid),
                promiseSucceeded: succeeded.contains(idString),
                promiseAttempted: attempted.contains(idString)
            )
        }
    }
}

@MainActor
public struct DragOutCellWrapper<Content: View>: NSViewRepresentable {
    let item: ShelfItem
    let onTap: (NSEvent.ModifierFlags) -> Void
    let onDragEnded: (DragOutResult) -> Void
    let multiItemsProvider: (() -> [ShelfItem])?
    let onMultiDragEnded: ((MultiDragOutResult) -> Void)?
    let content: Content

    public init(
        item: ShelfItem,
        onTap: @escaping () -> Void,
        onDragEnded: @escaping (DragOutResult) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            item: item,
            onTapWithModifiers: { _ in onTap() },
            onDragEnded: onDragEnded,
            multiItemsProvider: nil,
            onMultiDragEnded: nil,
            content: content
        )
    }

    public init(
        item: ShelfItem,
        onTapWithModifiers: @escaping (NSEvent.ModifierFlags) -> Void,
        onDragEnded: @escaping (DragOutResult) -> Void,
        multiItemsProvider: (() -> [ShelfItem])? = nil,
        onMultiDragEnded: ((MultiDragOutResult) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.item = item
        self.onTap = onTapWithModifiers
        self.onDragEnded = onDragEnded
        self.multiItemsProvider = multiItemsProvider
        self.onMultiDragEnded = onMultiDragEnded
        self.content = content()
    }

    public func makeNSView(context: Context) -> DragOutCellNSView {
        let view = DragOutCellNSView()
        view.item = item
        view.onTap = onTap
        view.onDragEnded = onDragEnded
        view.multiItemsProvider = multiItemsProvider
        view.onMultiDragEnded = onMultiDragEnded

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
        nsView.multiItemsProvider = multiItemsProvider
        nsView.onMultiDragEnded = onMultiDragEnded
        if let hosting = nsView.hostingView as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DragOutCellNSView,
        context: Context
    ) -> CGSize? {
        guard let hosting = nsView.hostingView else { return nil }
        return hosting.fittingSize
    }
}

@MainActor
public final class DragOutCellNSView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private static let log = Logger(subsystem: "dev.rod.shelf", category: "drag")
    private static let dragThreshold: CGFloat = 4.0

    var item: ShelfItem!
    var onTap: ((NSEvent.ModifierFlags) -> Void)?
    var onDragEnded: ((DragOutResult) -> Void)?
    var multiItemsProvider: (() -> [ShelfItem])?
    var onMultiDragEnded: ((MultiDragOutResult) -> Void)?
    weak var hostingView: NSView?

    nonisolated fileprivate let promiseOutcome = PromiseOutcome()
    nonisolated fileprivate let multiPromiseOutcome = MultiPromiseOutcome()

    private var dragStartPoint: NSPoint?
    private var dragStartEvent: NSEvent?
    private var didStartDrag: Bool = false

    public override var mouseDownCanMoveWindow: Bool { false }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return bounds.contains(point) ? self : nil
        default:
            return super.hitTest(point)
        }
    }

    public override var intrinsicContentSize: NSSize {
        guard let hosting = hostingView else { return super.intrinsicContentSize }
        let size = hosting.intrinsicContentSize
        if size.width >= 0 && size.height >= 0 {
            return size
        }
        return hosting.fittingSize
    }

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
            onTap?(event.modifierFlags)
        }
        didStartDrag = false
    }

    private func startDragSession(with event: NSEvent) {
        if let multiItems = multiItemsProvider?(), multiItems.count > 1 {
            startMultiDragSession(with: multiItems, event: event)
            return
        }
        promiseOutcome.reset()
        multiPromiseOutcome.reset(itemIDs: [])

        let writer = makePasteboardWriter(for: item)
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        configureDraggingItem(draggingItem, item: item, frame: bounds)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func startMultiDragSession(with items: [ShelfItem], event: NSEvent) {
        promiseOutcome.reset()
        multiPromiseOutcome.reset(itemIDs: items.map(\.id))
        let dragItems = items.enumerated().map { index, item in
            let writer = makePasteboardWriter(for: item, includeItemID: true)
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(index) * 3
            let frame = bounds.offsetBy(dx: offset, dy: -offset)
            configureDraggingItem(draggingItem, item: item, frame: frame)
            return draggingItem
        }
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.draggingFormation = .stack
    }

    private func configureDraggingItem(_ draggingItem: NSDraggingItem, item: ShelfItem, frame: CGRect) {
        guard
            let image = cleanDragImage(for: item),
            let imageFrame = aspectFitFrame(for: image.size, in: frame)
        else {
            draggingItem.draggingFrame = frame
            return
        }
        draggingItem.setDraggingFrame(imageFrame, contents: image)
    }

    private func cleanDragImage(for item: ShelfItem) -> NSImage? {
        switch item.kind {
        case .fileBookmark(let record):
            let resolver = BookmarkResolver()
            do {
                let resolution = try resolver.resolve(record)
                defer { resolver.release(resolution.url) }
                return sourceImage(from: resolution.url)
            } catch {
                Self.log.warning("Drag image bookmark resolve failed for \(record.originalPath, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }

        case .clipboardImage(let filename):
            guard let url = DefaultsBackend.clipboardImageURL(filename: filename) else { return nil }
            return sourceImage(from: url)

        case .webURL, .text:
            return nil
        }
    }

    private func sourceImage(from url: URL) -> NSImage? {
        ThumbnailService.sourceImageIfAvailable(for: url)
    }

    private func aspectFitFrame(for sourceSize: CGSize, in rect: CGRect) -> CGRect? {
        guard sourceSize.width > 0, sourceSize.height > 0, rect.width > 0, rect.height > 0 else {
            return nil
        }
        let scale = min(rect.width / sourceSize.width, rect.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func makePasteboardWriter(for item: ShelfItem, includeItemID: Bool = false) -> NSPasteboardWriting {
        switch item.kind {
        case .fileBookmark(let record):
            let typeIdentifier = Self.utiForFile(displayName: item.displayName)
            // Resolve once only to capture the `.fileURL` string for destinations
            // that ignore file promises; release the scope immediately since the
            // string alone does not require holding access. The promise write path
            // re-resolves when it actually needs to read the file.
            let fileURLString: String?
            do {
                let resolver = BookmarkResolver()
                let resolution = try resolver.resolve(record)
                defer { resolver.release(resolution.url) }
                fileURLString = resolution.url.absoluteString
            } catch {
                Self.log.warning("Drag-start bookmark resolve failed for \(record.originalPath, privacy: .public): \(String(describing: error), privacy: .public). Falling back to file-promise-only drag.")
                fileURLString = nil
            }

            var info: [String: Any] = [
                "kind": "fileBookmark",
                "record": record,
                "displayName": item.displayName,
                "internalShelfDrag": true,
            ]
            if includeItemID {
                info["itemID"] = item.id.rawValue.uuidString
            }
            if let fileURLString {
                info["fileURLString"] = fileURLString
            }
            let provider = FilePromiseProviderWithURL(fileType: typeIdentifier, delegate: self)
            provider.userInfo = info
            return provider

        case .clipboardImage(let filename):
            let resolvedURL = DefaultsBackend.clipboardImageURL(filename: filename)

            var info: [String: Any] = [
                "kind": "clipboardImage",
                "filename": filename,
                "internalShelfDrag": true,
            ]
            if includeItemID {
                info["itemID"] = item.id.rawValue.uuidString
            }
            if let url = resolvedURL {
                info["fileURLString"] = url.absoluteString
            }
            let provider = FilePromiseProviderWithURL(fileType: UTType.png.identifier, delegate: self)
            provider.userInfo = info
            return provider

        case .webURL(let url):
            let pbItem = NSPasteboardItem()
            pbItem.setString("1", forType: DragItemFactory.internalShelfDragType)
            pbItem.setString(url.absoluteString, forType: .URL)
            pbItem.setString(url.absoluteString, forType: .string)
            return pbItem

        case .text(let text):
            let pbItem = NSPasteboardItem()
            pbItem.setString("1", forType: DragItemFactory.internalShelfDragType)
            pbItem.setString(text, forType: .string)
            return pbItem
        }
    }

    nonisolated private static func utiForFile(displayName: String) -> String {
        let ext = (displayName as NSString).pathExtension
        if ext.isEmpty { return UTType.data.identifier }
        return UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
    }

    nonisolated private static func suggestedBaseName(from name: String) -> String {
        let stripped = (name as NSString).deletingPathExtension
        return stripped.isEmpty ? name : stripped
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication:
            return []
        case .outsideApplication:
            return [.move, .copy, .generic, .link]
        @unknown default:
            return [.copy]
        }
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let item, let onDragEnded else { return }

        // Wait for promise writes before reading success flags.
        if !operation.isEmpty {
            promiseOutcome.queue.waitUntilAllOperationsAreFinished()
            multiPromiseOutcome.queue.waitUntilAllOperationsAreFinished()
        }

        let multiOutcomes = multiPromiseOutcome.snapshot()
        if !multiOutcomes.isEmpty, let onMultiDragEnded {
            Self.log.info(
                "Multi drag-out ended count=\(multiOutcomes.count, privacy: .public) operation=\(operation.rawValue, privacy: .public)"
            )
            onMultiDragEnded(MultiDragOutResult(outcomes: multiOutcomes, operation: operation))
            return
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

    nonisolated public func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        guard let info = filePromiseProvider.userInfo as? [String: Any] else {
            return "Untitled"
        }
        if let displayName = info["displayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let filename = info["filename"] as? String, !filename.isEmpty {
            return filename
        }
        return "Untitled"
    }

    nonisolated public func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        if let info = filePromiseProvider.userInfo as? [String: Any],
           info["itemID"] is String {
            return multiPromiseOutcome.queue
        }
        return promiseOutcome.queue
    }

    nonisolated public func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Mark before guards so failed promises cannot look like direct `.fileURL` reads.
        let itemIDString = Self.promiseItemIDString(filePromiseProvider)
        markPromiseAttempted(itemIDString)
        guard
            let info = filePromiseProvider.userInfo as? [String: Any],
            let kind = info["kind"] as? String
        else {
            completionHandler(Self.promiseError(code: -1, message: "Promise has no item info"))
            return
        }

        switch kind {
        case "fileBookmark":
            writeFileBookmarkPromise(info: info, to: url, itemIDString: itemIDString, completionHandler: completionHandler)
        case "clipboardImage":
            writeClipboardImagePromise(info: info, to: url, itemIDString: itemIDString, completionHandler: completionHandler)
        default:
            completionHandler(Self.promiseError(code: -5, message: "Unknown promise kind"))
        }
    }
    nonisolated private func writeFileBookmarkPromise(
        info: [String: Any],
        to url: URL,
        itemIDString: String?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let record = info["record"] as? BookmarkRecord else {
            Self.log.error("writePromiseTo: missing BookmarkRecord in userInfo")
            completionHandler(Self.promiseError(code: -2, message: "Promise missing bookmark record"))
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
            markPromiseSucceeded(itemIDString)
            completionHandler(nil)
        } catch {
            Self.log.error("writePromiseTo: copy failed: \(String(describing: error), privacy: .public)")
            completionHandler(error)
        }
    }
    nonisolated private func writeClipboardImagePromise(
        info: [String: Any],
        to url: URL,
        itemIDString: String?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let filename = info["filename"] as? String else {
            completionHandler(Self.promiseError(code: -3, message: "Promise missing image filename"))
            return
        }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            completionHandler(Self.promiseError(code: -4, message: "Application Support directory unreachable"))
            return
        }

        let source = appSupport
            .appendingPathComponent("Shelf", isDirectory: true)
            .appendingPathComponent("clipboard-images", isDirectory: true)
            .appendingPathComponent(filename)
        Self.log.info("writePromiseTo: clipboardImage source=\(source.path, privacy: .public) dest=\(url.path, privacy: .public)")

        do {
            try FileManager.default.copyItem(at: source, to: url)
            markPromiseSucceeded(itemIDString)
            completionHandler(nil)
        } catch {
            Self.log.error("writePromiseTo: clipboard copy failed: \(String(describing: error), privacy: .public)")
            completionHandler(error)
        }
    }
    nonisolated private func markPromiseAttempted(_ itemIDString: String?) {
        if let itemIDString {
            multiPromiseOutcome.markAttempted(itemIDString)
        } else {
            promiseOutcome.markAttempted()
        }
    }

    nonisolated private func markPromiseSucceeded(_ itemIDString: String?) {
        if let itemIDString {
            multiPromiseOutcome.markSucceeded(itemIDString)
        } else {
            promiseOutcome.markSucceeded()
        }
    }

    nonisolated private static func promiseItemIDString(_ filePromiseProvider: NSFilePromiseProvider) -> String? {
        (filePromiseProvider.userInfo as? [String: Any])?["itemID"] as? String
    }

    nonisolated private static func promiseError(code: Int, message: String) -> NSError {
        NSError(domain: "dev.rod.shelf.drag", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
