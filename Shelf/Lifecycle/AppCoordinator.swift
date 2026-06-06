import AppKit
import Combine
import CryptoKit
import OSLog
import ShelfCore
import SwiftUI

@MainActor
public final class AppCoordinator {
    private static let expandedPanelSize = CGSize(width: 280, height: 280)
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")

    private let defaultsBackend: DefaultsBackend
    private let shelfStore: ShelfStore
    private let bookmarkResolver: BookmarkResolver

    private let hotkeyManager: HotkeyManager
    private let shakeDetector: ShakeDetector
    private let menuBar: MenuBarController

    private let windowManager: ShelfWindowManager
    private let thumbnailService: ThumbnailService
    private let quickLook: QuickLookCoordinator

    private let promiseDelegate: FilePromiseDelegate
    private let dragOutSource: DragOutSource

    private var viewModel: ShelfViewModel?
    private var collapsedSize: CGSize?

    public init() {
        self.defaultsBackend = DefaultsBackend()
        self.bookmarkResolver = BookmarkResolver()
        self.thumbnailService = ThumbnailService()
        self.promiseDelegate = FilePromiseDelegate(resolver: bookmarkResolver)
        self.dragOutSource = DragOutSource(promiseDelegate: promiseDelegate)
        self.shelfStore = defaultsBackend.makeShelfStore()
        self.hotkeyManager = HotkeyManager()
        self.shakeDetector = ShakeDetector(config: .defaultMedium)
        self.menuBar = MenuBarController()
        self.windowManager = ShelfWindowManager()
        self.quickLook = QuickLookCoordinator(resolver: bookmarkResolver)
    }

    public func bootstrap() {
        defaultsBackend.ensureApplicationSupport()
        wireCallbacks()
        deduplicateStoredShelf()
        sweepOrphanedManagedFiles()
        shakeDetector.start()
        log.info("AppCoordinator bootstrapped")
    }

    public func teardown() {
        shakeDetector.stop()
        windowManager.closeAll()
        log.info("AppCoordinator teardown")
    }

    private func wireCallbacks() {
        hotkeyManager.onShowShelf = { [weak self] in
            self?.showShelfAtCursor()
        }
        quickLook.onDidClose = { [weak self] in
            self?.log.info("Quick Look did close; restoring shelf focus")
            self?.windowManager.focusShelf(wantsKey: true)
        }

        shakeDetector.onShakeDuringDrag = { [weak self] _ in
            self?.showShelfAtCursor()
        }

        menuBar.onShowShelf = { [weak self] in
            self?.showShelfAtCursor()
        }
        menuBar.onFocusShelf = { [weak self] in
            self?.windowManager.focusShelf(wantsKey: true)
        }
        menuBar.onAbout = {
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        menuBar.onQuit = {
            NSApp.terminate(nil)
        }

        windowManager.onShelfClosed = { [weak self] in
            guard let self else { return }
            self.viewModel = nil
            self.collapsedSize = nil
            self.publishActiveShelfToMenu()
        }

        shelfStore.onChange = { [weak self] in
            Task { @MainActor in
                self?.publishActiveShelfToMenu()
            }
        }
    }

    private func showShelfAtCursor() {
        if windowManager.visibleShelfCount > 0 {
            windowManager.focusShelf()
            log.debug("Focused existing shelf")
            return
        }

        let existingShelf = shelfStore.current()
        let shelf = existingShelf ?? ShelfGroup(name: "")
        if existingShelf == nil {
            shelfStore.set(shelf)
        }
        let viewModel = ShelfViewModel(shelf: shelf)
        self.viewModel = viewModel
        let hosting = NSHostingView(
            rootView: ShelfContentView(
                viewModel: viewModel,
                resolver: bookmarkResolver,
                thumbnailService: thumbnailService,
                onSingleDragEnded: { [weak self] result in
                    self?.handleDragOutEnded(result)
                },
                onMultiDragEnded: { [weak self] result in
                    self?.handleMultiDragOutEnded(result)
                },
                onDeleteItems: { [weak self] itemIDs in
                    self?.removeItems(itemIDs)
                },
                onDropItems: { [weak self] items in
                    self?.appendItems(items)
                },
                onCollapseRequested: { [weak viewModel] in
                    viewModel?.setExpanded(false)
                },
                onClose: { [weak self] in
                    self?.clearAndCloseShelf()
                }
            )
        )
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        let base = PanelPositioner.computeOrigin(
            forCursor: PanelPositioner.liveCursor(),
            screens: PanelPositioner.liveScreens()
        )
        windowManager.openShelf(
            shelf.id,
            contentView: hosting,
            baseOrigin: base,
            wantsKey: true
        )
        wireWindowAnimation(viewModel)
        wireKeyHandling(viewModel)
        publishActiveShelfToMenu()
        log.info("Showed shelf id=\(shelf.id.rawValue.uuidString, privacy: .public)")
    }

    private func wireKeyHandling(_ viewModel: ShelfViewModel) {
        guard let controller = windowManager.shelfController() else { return }
        // Handled locally by the panel, so these act only while the shelf is the
        // key window — never as system-wide hotkeys that swallow keys globally.
        // Keys also yield to focused text fields, which consume them first.
        controller.onKeyDown = { [weak self, weak viewModel] event in
            guard let self else { return false }
            switch event.keyCode {
            case 53: // Esc — close the shelf
                self.windowManager.closeShelf()
                return true
            case 49: // Space — toggle Quick Look for the focused shelf
                self.invokeQuickLookForKeyShelf()
                return true
            case 51, 117: // Delete / Forward Delete — remove selection (expanded only)
                guard let viewModel, viewModel.isExpanded else { return false }
                let selection = viewModel.drawerSelection
                guard !selection.isEmpty else { return true }
                self.removeItems(selection)
                return true
            default:
                return false
            }
        }
    }

    private func clearAndCloseShelf() {
        shelfStore.remove()
        windowManager.closeShelf()
    }

    private func publishActiveShelfToMenu() {
        menuBar.activeShelf = windowManager.visibleShelfCount > 0 ? shelfStore.current() : nil
    }

    private func appendItems(_ items: [ShelfItem]) {
        guard let currentShelf = shelfStore.current() else {
            log.warning("Drop append skipped because shelf is missing")
            return
        }

        let uniqueItems = uniqueItemsForAppend(items, existingItems: currentShelf.items)
        let insertedCount = uniqueItems.count
        let skippedDuplicateCount = items.count - uniqueItems.count

        shelfStore.update { shelf in
            guard !uniqueItems.isEmpty else { return }
            shelf.items.insert(contentsOf: uniqueItems, at: 0)
            shelf.lastUsedAt = Date()
        }
        if let updated = shelfStore.current(),
           let viewModel {
            viewModel.reload(from: updated)
        }
        log.info(
            "Appended \(insertedCount, privacy: .public) item(s) to shelf; skipped \(skippedDuplicateCount, privacy: .public) duplicate file item(s)"
        )
    }

    private func uniqueItemsForAppend(_ items: [ShelfItem], existingItems: [ShelfItem]) -> [ShelfItem] {
        var knownKeys = Set(existingItems.flatMap(duplicateKeys(for:)))
        var uniqueItems: [ShelfItem] = []

        for item in items {
            let keys = duplicateKeys(for: item)
            if !keys.isEmpty {
                guard keys.isDisjoint(with: knownKeys) else { continue }
                knownKeys.formUnion(keys)
            }
            uniqueItems.append(item)
        }

        return uniqueItems
    }

    private func deduplicateStoredShelf() {
        guard let currentShelf = shelfStore.current() else { return }
        let uniqueItems = uniqueItemsForAppend(currentShelf.items, existingItems: [])
        let removedCount = currentShelf.items.count - uniqueItems.count
        guard removedCount > 0 else { return }

        shelfStore.update { shelf in
            shelf.items = uniqueItems
            shelf.lastUsedAt = Date()
        }
        log.info("Removed \(removedCount, privacy: .public) duplicate existing shelf item(s)")
    }

    private func removeItems(_ itemIDs: Set<ItemID>) {
        guard !itemIDs.isEmpty else { return }
        shelfStore.update { shelf in
            shelf.items.removeAll { itemIDs.contains($0.id) }
            shelf.lastUsedAt = Date()
        }
        if let updated = shelfStore.current() {
            if updated.items.isEmpty {
                removeEmptyShelf()
                return
            }
            viewModel?.reload(from: updated)
        }
        log.info("Removed \(itemIDs.count, privacy: .public) item(s) from shelf")
    }

    private func removeEmptyShelf() {
        guard let current = shelfStore.current(), current.items.isEmpty else { return }
        shelfStore.remove()
        windowManager.closeShelf()
        log.info("Removed empty shelf")
    }

    private func wireWindowAnimation(_ viewModel: ShelfViewModel) {
        viewModel.animateWindow = { [weak self] expanded, duration, completion in
            guard let self, let controller = self.windowManager.shelfController() else {
                completion()
                return
            }
            let targetSize: CGSize
            if expanded {
                self.collapsedSize = controller.panel.frame.size
                targetSize = Self.expandedPanelSize
            } else {
                targetSize = self.collapsedSize
                    ?? ShelfWindowController.defaultPanelSize
                self.collapsedSize = nil
            }
            controller.setFrameSize(
                targetSize,
                animated: true,
                duration: duration,
                completion: completion
            )
        }
    }

    private func invokeQuickLookForKeyShelf() {
        log.debug("Quick Look hotkey received shelfKey=\(self.windowManager.isShelfKey(), privacy: .public) quickLookVisible=\(self.quickLook.isVisible, privacy: .public)")
        if quickLook.closeIfVisible() {
            return
        }

        guard windowManager.isShelfKey() else {
            log.debug("Quick Look skipped: no key shelf")
            return
        }
        guard let viewModel else {
            log.debug("Quick Look skipped: no view model")
            return
        }

        let targets = viewModel.quickLookTargetItems
        let previewURLs = collectQuickLookPreviewURLs(from: targets)

        guard !previewURLs.previews.isEmpty else {
            log.debug("Quick Look skipped: no previewable items in selection")
            return
        }

        quickLook.show(
            previews: previewURLs.previews,
            bookmarkResolutions: previewURLs.resolutions,
            sourceFramesByItemID: viewModel.quickLookSourceFrames
        )
    }

    private func collectQuickLookPreviewURLs(
        from items: [ShelfItem]
    ) -> (resolutions: [BookmarkResolver.Resolution], previews: [QuickLookCoordinator.Preview]) {
        var resolutions: [BookmarkResolver.Resolution] = []
        var previews: [QuickLookCoordinator.Preview] = []

        for item in items {
            appendQuickLookPreviewURL(for: item, resolutions: &resolutions, previews: &previews)
        }

        return (resolutions, previews)
    }

    private func appendQuickLookPreviewURL(
        for item: ShelfItem,
        resolutions: inout [BookmarkResolver.Resolution],
        previews: inout [QuickLookCoordinator.Preview]
    ) {
        switch item.kind {
        case .fileBookmark(let record):
            do {
                let resolution = try bookmarkResolver.resolve(record)
                resolutions.append(resolution)
                previews.append(QuickLookCoordinator.Preview(itemID: item.id, url: resolution.url))
            } catch {
                log.warning("Quick Look bookmark resolve failed for id=\(item.id.rawValue.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            }

        case .clipboardImage(let filename):
            if let url = clipboardImageURL(filename: filename) {
                previews.append(QuickLookCoordinator.Preview(itemID: item.id, url: url))
            }

        case .webURL, .text:
            break
        }
    }

    private func clipboardImageURL(filename: String) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let url = appSupport
            .appendingPathComponent("Shelf", isDirectory: true)
            .appendingPathComponent("clipboard-images", isDirectory: true)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func handleDragOutEnded(_ result: DragOutResult) {
        let operation = result.operation
        let itemID = result.itemID

        if operation.isEmpty {
            log.debug("Drag-out cancelled for item id=\(itemID.rawValue.uuidString, privacy: .public)")
            return
        }

        guard let shelf = shelfStore.current() else {
            log.warning("Drag-out: shelf not found in store")
            return
        }
        guard let item = shelf.items.first(where: { $0.id == itemID }) else {
            log.warning("Drag-out: item id=\(itemID.rawValue.uuidString, privacy: .public) not found in shelf")
            return
        }

        let isConfirmedMove = isDragOutConfirmed(item: item, result: result)

        if isConfirmedMove {
            deleteOriginalFile(for: item)
            shelfStore.update { shelf in
                shelf.items.removeAll { $0.id == itemID }
                shelf.lastUsedAt = Date()
            }
            if let updated = shelfStore.current() {
                if updated.items.isEmpty {
                    removeEmptyShelf()
                    return
                }
                viewModel?.reload(from: updated)
            }
            log.info(
                "Drag-out MOVE completed id=\(itemID.rawValue.uuidString, privacy: .public) operation=\(operation.rawValue, privacy: .public)"
            )
        } else {
            log.info(
                "Drag-out completed without promise confirmation; preserving original and keeping cell so user can retry. id=\(itemID.rawValue.uuidString, privacy: .public) operation=\(operation.rawValue, privacy: .public) promiseAttempted=\(result.promiseAttempted, privacy: .public) promiseSucceeded=\(result.promiseSucceeded, privacy: .public)"
            )
        }
    }

    private func handleMultiDragOutEnded(_ result: MultiDragOutResult) {
        guard !result.operation.isEmpty else {
            log.debug("Multi drag-out cancelled")
            return
        }
        guard let shelf = shelfStore.current() else {
            log.warning("Multi drag-out: shelf not found in store")
            return
        }

        let confirmedIDs = Set(result.outcomes.compactMap { outcome -> ItemID? in
            guard let item = shelf.items.first(where: { $0.id == outcome.itemID }) else { return nil }
            return isMultiDragOutConfirmed(item: item, outcome: outcome, operation: result.operation)
                ? outcome.itemID
                : nil
        })
        guard !confirmedIDs.isEmpty else {
            log.info("Multi drag-out completed without promise confirmation; preserving all shelf items")
            return
        }

        for item in shelf.items where confirmedIDs.contains(item.id) {
            deleteOriginalFile(for: item)
        }
        shelfStore.update { shelf in
            shelf.items.removeAll { confirmedIDs.contains($0.id) }
            shelf.lastUsedAt = Date()
        }
        if let updated = shelfStore.current() {
            if updated.items.isEmpty {
                removeEmptyShelf()
                return
            }
            viewModel?.reload(from: updated)
        }
        log.info("Multi drag-out removed \(confirmedIDs.count, privacy: .public) confirmed item(s) from shelf")
    }

    private func deleteOriginalFile(for item: ShelfItem) {
        switch item.kind {
        case .fileBookmark(let record):
            do {
                let resolution = try bookmarkResolver.resolve(record)
                defer { bookmarkResolver.release(resolution.url) }
                try FileManager.default.removeItem(at: resolution.url)
                log.info("Deleted original file at \(record.originalPath, privacy: .public) after .move drag-out")
            } catch {
                log.warning("Failed to delete original file at \(record.originalPath, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        case .clipboardImage(let filename):
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return }
            let url = appSupport
                .appendingPathComponent("Shelf", isDirectory: true)
                .appendingPathComponent("clipboard-images", isDirectory: true)
                .appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        case .webURL, .text:
            break
        }
    }

    private func sweepOrphanedManagedFiles() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let shelfBase = appSupport.appendingPathComponent("Shelf", isDirectory: true)
        let itemsDir = shelfBase.appendingPathComponent("items", isDirectory: true)
        let clipboardDir = shelfBase.appendingPathComponent("clipboard-images", isDirectory: true)

        var liveItemDirs: Set<String> = []
        var liveClipboardFiles: Set<String> = []
        if let shelf = shelfStore.current() {
            for item in shelf.items {
                switch item.kind {
                case .fileBookmark:
                    liveItemDirs.insert(item.id.rawValue.uuidString)
                case .clipboardImage(let filename):
                    liveClipboardFiles.insert(filename)
                case .webURL, .text:
                    break
                }
            }
        }

        if let entries = try? fm.contentsOfDirectory(at: itemsDir, includingPropertiesForKeys: nil) {
            for entry in entries where !liveItemDirs.contains(entry.lastPathComponent) {
                try? fm.removeItem(at: entry)
                log.info("Swept orphaned item directory \(entry.lastPathComponent, privacy: .public)")
            }
        }

        if let entries = try? fm.contentsOfDirectory(at: clipboardDir, includingPropertiesForKeys: nil) {
            for entry in entries where !liveClipboardFiles.contains(entry.lastPathComponent) {
                try? fm.removeItem(at: entry)
                log.info("Swept orphaned clipboard image \(entry.lastPathComponent, privacy: .public)")
            }
        }
    }
}

private extension AppCoordinator {
    /// File and image drags use file promises; links and text use direct pasteboard data.
    func isDragOutConfirmed(item: ShelfItem, result: DragOutResult) -> Bool {
        switch item.kind {
        case .webURL, .text:
            return !result.operation.isEmpty
        case .fileBookmark, .clipboardImage:
            return result.promiseAttempted && result.promiseSucceeded
        }
    }

    func isMultiDragOutConfirmed(
        item: ShelfItem,
        outcome: MultiDragOutResult.PerItem,
        operation: NSDragOperation
    ) -> Bool {
        switch item.kind {
        case .webURL, .text:
            return !operation.isEmpty
        case .fileBookmark, .clipboardImage:
            return outcome.promiseAttempted && outcome.promiseSucceeded
        }
    }

    func duplicateKeys(for item: ShelfItem) -> Set<String> {
        switch item.kind {
        case .fileBookmark(let record):
            return fileBookmarkDuplicateKeys(record)
        case .clipboardImage(let filename):
            guard let url = clipboardImageURL(filename: filename) else { return [] }
            return fileDuplicateKeys(for: url)
        case .webURL, .text:
            return []
        }
    }

    func fileBookmarkDuplicateKeys(_ record: BookmarkRecord) -> Set<String> {
        if !record.originalPath.isEmpty {
            return fileDuplicateKeys(for: URL(fileURLWithPath: record.originalPath))
        }

        do {
            let resolution = try bookmarkResolver.resolve(record)
            defer { bookmarkResolver.release(resolution.url) }
            return fileDuplicateKeys(for: resolution.url)
        } catch {
            log.warning("Could not resolve bookmark while checking duplicates: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    func fileDuplicateKeys(for url: URL) -> Set<String> {
        var keys: Set<String> = ["path:\(normalizedFilePath(url))"]
        if let hash = fileContentHash(for: url) {
            keys.insert("sha256:\(hash)")
        }
        return keys
    }

    func normalizedFilePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func fileContentHash(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
