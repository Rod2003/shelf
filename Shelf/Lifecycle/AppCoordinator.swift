import AppKit
import Combine
import OSLog
import ShelfCore

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
            self?.showShelfAtCursor(wantsKey: true)
        }
        hotkeyManager.onCloseFrontmost = { [weak self] in
            guard let self else { return }
            guard self.windowManager.isShelfKey() else { return }
            self.windowManager.closeShelf()
        }
        hotkeyManager.onQuickLook = { [weak self] in
            self?.invokeQuickLookForKeyShelf()
        }

        shakeDetector.onShakeDuringDrag = { [weak self] _ in
            self?.showShelfAtCursor(wantsKey: false)
        }

        menuBar.onShowShelf = { [weak self] in
            self?.showShelfAtCursor(wantsKey: true)
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

        // Gate bare Space or it steals Space from every app.
        windowManager.onShelfBecameKey = { [weak self] in
            guard let self else { return }
            self.hotkeyManager.setEscEnabled(true)
            self.hotkeyManager.setSpaceEnabled(true)
        }
        windowManager.onShelfResignedKey = { [weak self] in
            guard let self else { return }
            if !self.windowManager.isShelfKey() {
                self.hotkeyManager.setEscEnabled(false)
                self.hotkeyManager.setSpaceEnabled(false)
            }
        }
        windowManager.onShelfClosed = { [weak self] in
            self?.viewModel = nil
            self?.collapsedSize = nil
            self?.publishActiveShelfToMenu()
        }

        shelfStore.onChange = { [weak self] in
            Task { @MainActor in
                self?.publishActiveShelfToMenu()
            }
        }
    }

    private func showShelfAtCursor(wantsKey: Bool) {
        if windowManager.visibleShelfCount > 0 {
            windowManager.focusShelf(wantsKey: wantsKey)
            log.debug("Focused existing shelf wantsKey=\(wantsKey, privacy: .public)")
            return
        }

        let existingShelf = shelfStore.current()
        let shelf = existingShelf ?? ShelfGroup(name: "")
        if existingShelf == nil {
            shelfStore.set(shelf)
        }
        let viewModel = ShelfViewModel(shelf: shelf)
        self.viewModel = viewModel
        let contentView = ContentViewFactory.makeContentView(
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
        let base = PanelPositioner.computeOrigin(
            forCursor: PanelPositioner.liveCursor(),
            screens: PanelPositioner.liveScreens()
        )
        windowManager.openShelf(
            shelf.id,
            contentView: contentView,
            baseOrigin: base,
            wantsKey: wantsKey
        )
        wireWindowAnimation(viewModel)
        wireKeyHandling(viewModel)
        publishActiveShelfToMenu()
        log.info("Showed shelf id=\(shelf.id.rawValue.uuidString, privacy: .public)")
    }

    private func wireKeyHandling(_ viewModel: ShelfViewModel) {
        guard let controller = windowManager.shelfController() else { return }
        controller.onKeyDown = { [weak self, weak viewModel] event in
            guard let self, let viewModel else { return false }
            // 51 = Delete (backspace), 117 = Forward Delete
            guard event.keyCode == 51 || event.keyCode == 117 else { return false }
            guard viewModel.isExpanded else { return false }
            let selection = viewModel.drawerSelection
            guard !selection.isEmpty else { return true }
            viewModel.removeAll(itemIDs: selection)
            if viewModel.items.isEmpty {
                viewModel.setExpanded(false)
            }
            self.removeItems(selection)
            return true
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
        shelfStore.update { shelf in
            shelf.items.insert(contentsOf: items, at: 0)
            shelf.lastUsedAt = Date()
        }
        if let updated = shelfStore.current(),
           let viewModel {
            viewModel.reload(from: updated)
        }
        log.info("Appended \(items.count, privacy: .public) item(s) to shelf")
    }

    private func removeItems(_ itemIDs: Set<ItemID>) {
        guard !itemIDs.isEmpty else { return }
        shelfStore.update { shelf in
            shelf.items.removeAll { itemIDs.contains($0.id) }
            shelf.lastUsedAt = Date()
        }
        if let updated = shelfStore.current(),
           let viewModel {
            if updated.items.isEmpty {
                viewModel.setExpanded(false)
            }
            viewModel.reload(from: updated)
        }
        log.info("Removed \(itemIDs.count, privacy: .public) item(s) from shelf")
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
        guard windowManager.isShelfKey() else {
            log.debug("Quick Look skipped: no key shelf")
            return
        }
        guard let viewModel else {
            log.debug("Quick Look skipped: no view model")
            return
        }

        let targets = viewModel.quickLookTargetItems
        guard !targets.isEmpty else {
            log.debug("Quick Look skipped: no target items")
            return
        }

        var resolutions: [BookmarkResolver.Resolution] = []
        var unscopedURLs: [URL] = []

        for item in targets {
            switch item.kind {
            case .fileBookmark(let record):
                do {
                    let resolution = try bookmarkResolver.resolve(record)
                    resolutions.append(resolution)
                } catch {
                    log.warning("Quick Look bookmark resolve failed for id=\(item.id.rawValue.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                }

            case .clipboardImage(let filename):
                if let url = clipboardImageURL(filename: filename) {
                    unscopedURLs.append(url)
                }

            case .webURL, .text:
                continue
            }
        }

        guard !resolutions.isEmpty || !unscopedURLs.isEmpty else {
            log.debug("Quick Look skipped: no previewable items in selection")
            return
        }

        quickLook.show(bookmarkResolutions: resolutions, unscopedURLs: unscopedURLs)
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

        let isConfirmedMove = result.promiseAttempted && result.promiseSucceeded

        if isConfirmedMove {
            deleteOriginalFile(for: item)
            shelfStore.update { shelf in
                shelf.items.removeAll { $0.id == itemID }
                shelf.lastUsedAt = Date()
            }
            if let updated = shelfStore.current(),
               let viewModel {
                viewModel.reload(from: updated)
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

        let confirmedIDs = Set(result.outcomes
            .filter { $0.promiseAttempted && $0.promiseSucceeded }
            .map(\.itemID))
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
        if let updated = shelfStore.current(),
           let viewModel {
            if updated.items.isEmpty {
                viewModel.setExpanded(false)
            }
            viewModel.reload(from: updated)
        }
        log.info("Multi drag-out removed \(confirmedIDs.count, privacy: .public) confirmed item(s) from shelf")
    }

    private func deleteOriginalFile(for item: ShelfItem) {
        switch item.kind {
        case .fileBookmark(let record):
            do {
                let resolution = try bookmarkResolver.resolve(record)
                try FileManager.default.removeItem(at: resolution.url)
                // Do not release a URL that no longer exists.
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
