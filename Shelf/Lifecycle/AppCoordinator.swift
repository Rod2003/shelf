import AppKit
import Combine
import OSLog
import ShelfCore

@MainActor
public final class AppCoordinator {
    private static let expandedPanelSize = CGSize(width: 280, height: 360)
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

    private var viewModels: [ShelfGroupID: ShelfViewModel] = [:]
    private var expansionCancellables: [ShelfGroupID: AnyCancellable] = [:]
    private var collapsedSizesByShelf: [ShelfGroupID: CGSize] = [:]

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
        self.quickLook = QuickLookCoordinator()
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
        hotkeyManager.onNewShelf = { [weak self] in
            self?.createNewShelfAtCursor()
        }
        hotkeyManager.onCloseFrontmost = { [weak self] in
            guard let self else { return }
            guard let id = self.windowManager.currentlyKeyShelf() else { return }
            self.windowManager.closeShelf(id)
        }
        hotkeyManager.onQuickLook = { [weak self] in
            self?.invokeQuickLookForKeyShelf()
        }

        shakeDetector.onShakeDuringDrag = { [weak self] _ in
            self?.createNewShelfAtCursor()
        }

        menuBar.onNewShelf = { [weak self] in
            self?.createNewShelfAtCursor()
        }
        menuBar.onSelectActive = { [weak self] id in
            self?.windowManager.focusShelf(id)
        }
        menuBar.onAbout = {
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        menuBar.onQuit = {
            NSApp.terminate(nil)
        }

        // Gate bare Space or it steals Space from every app.
        windowManager.onShelfBecameKey = { [weak self] _ in
            guard let self else { return }
            self.hotkeyManager.setEscEnabled(true)
            self.hotkeyManager.setSpaceEnabled(true)
        }
        windowManager.onShelfResignedKey = { [weak self] _ in
            guard let self else { return }
            if self.windowManager.currentlyKeyShelf() == nil {
                self.hotkeyManager.setEscEnabled(false)
                self.hotkeyManager.setSpaceEnabled(false)
            }
        }
        windowManager.onShelfClosed = { [weak self] id in
            self?.viewModels.removeValue(forKey: id)
            self?.expansionCancellables.removeValue(forKey: id)
            self?.collapsedSizesByShelf.removeValue(forKey: id)
            self?.publishActiveShelvesToMenu()
        }

        shelfStore.onChange = { [weak self] in
            Task { @MainActor in
                self?.publishActiveShelvesToMenu()
            }
        }
    }

    private func createNewShelfAtCursor() {
        let shelf = ShelfGroup(name: "")
        shelfStore.add(shelf)
        let viewModel = ShelfViewModel(shelf: shelf)
        viewModels[shelf.id] = viewModel
        let shelfID = shelf.id
        let contentView = ContentViewFactory.makeContentView(
            viewModel: viewModel,
            resolver: bookmarkResolver,
            thumbnailService: thumbnailService,
            onSingleDragEnded: { [weak self] result in
                self?.handleDragOutEnded(result, fromShelf: shelfID)
            },
            onMultiDragEnded: { [weak self] result in
                self?.handleMultiDragOutEnded(result, fromShelf: shelfID)
            },
            onDeleteItems: { [weak self] itemIDs in
                self?.removeItems(itemIDs, from: shelfID)
            },
            onCollapseRequested: { [weak viewModel] in
                viewModel?.isExpanded = false
            },
            onClose: { [weak self] in
                self?.windowManager.closeShelf(shelfID)
            }
        )
        wireExpansionObserver(viewModel, shelfID: shelfID)
        wireDragIn(on: contentView, for: shelf.id)
        let base = PanelPositioner.computeOrigin(
            forCursor: PanelPositioner.liveCursor(),
            screens: PanelPositioner.liveScreens()
        )
        windowManager.openShelf(shelf.id, contentView: contentView, baseOrigin: base)
        publishActiveShelvesToMenu()
        log.info("Created new shelf id=\(shelf.id.rawValue.uuidString, privacy: .public)")
    }

    private func publishActiveShelvesToMenu() {
        let openIDs = Set(windowManager.openShelfIDs())
        let openShelves = shelfStore.all().filter { openIDs.contains($0.id) }
        menuBar.activeShelves = openShelves.sorted { $0.createdAt > $1.createdAt }
    }

    private func wireDragIn(on contentView: NSView, for shelfID: ShelfGroupID) {
        let dragIn = DragInView(frame: contentView.bounds)
        dragIn.autoresizingMask = [.width, .height]
        dragIn.onDrop = { [weak self] items in
            self?.appendItems(items, to: shelfID)
        }
        // Keep drag receiving below SwiftUI so taps still land on the hosting view.
        contentView.addSubview(
            dragIn,
            positioned: .below,
            relativeTo: contentView.subviews.first
        )
    }

    private func appendItems(_ items: [ShelfItem], to shelfID: ShelfGroupID) {
        shelfStore.update(shelfID: shelfID) { shelf in
            shelf.items.insert(contentsOf: items, at: 0)
            shelf.lastUsedAt = Date()
        }
        if let updated = shelfStore.get(shelfID: shelfID),
           let viewModel = viewModels[shelfID] {
            viewModel.reload(from: updated)
        }
        log.info("Appended \(items.count, privacy: .public) item(s) to shelf id=\(shelfID.rawValue.uuidString, privacy: .public)")
    }

    private func removeItems(_ itemIDs: Set<ItemID>, from shelfID: ShelfGroupID) {
        guard !itemIDs.isEmpty else { return }
        shelfStore.update(shelfID: shelfID) { shelf in
            shelf.items.removeAll { itemIDs.contains($0.id) }
            shelf.lastUsedAt = Date()
        }
        if let updated = shelfStore.get(shelfID: shelfID),
           let viewModel = viewModels[shelfID] {
            if updated.items.isEmpty {
                viewModel.isExpanded = false
            }
            viewModel.reload(from: updated)
        }
        log.info("Removed \(itemIDs.count, privacy: .public) item(s) from shelf id=\(shelfID.rawValue.uuidString, privacy: .public)")
    }

    private func wireExpansionObserver(_ viewModel: ShelfViewModel, shelfID: ShelfGroupID) {
        expansionCancellables[shelfID] = viewModel.$isExpanded
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] expanded in
                DispatchQueue.main.async {
                    self?.handleExpansionChange(shelfID: shelfID, expanded: expanded)
                }
            }
    }

    private func handleExpansionChange(shelfID: ShelfGroupID, expanded: Bool) {
        guard let controller = windowManager.controller(for: shelfID) else { return }
        if expanded {
            let currentSize = controller.panel.frame.size
            collapsedSizesByShelf[shelfID] = currentSize
            controller.setFrameSize(
                Self.expandedPanelSize,
                animated: true,
                bouncy: true
            )
        } else {
            let targetSize = collapsedSizesByShelf.removeValue(forKey: shelfID)
                ?? ShelfWindowController.defaultPanelSize
            controller.setFrameSize(targetSize, animated: true, bouncy: true)
        }
    }

    private func invokeQuickLookForKeyShelf() {
        guard let id = windowManager.currentlyKeyShelf() else {
            log.debug("Quick Look skipped: no key shelf")
            return
        }
        guard let viewModel = viewModels[id] else {
            log.debug("Quick Look skipped: no view model for shelf id=\(id.rawValue.uuidString, privacy: .public)")
            return
        }
        let targetItem = viewModel.quickLookTargetItem
        guard let item = targetItem else {
            log.debug("Quick Look skipped: shelf id=\(id.rawValue.uuidString, privacy: .public) has no items")
            return
        }

        switch item.kind {
        case .fileBookmark(let record):
            do {
                let resolution = try bookmarkResolver.resolve(record)
                quickLook.show(urls: [resolution.url])
                // Do not release here; Quick Look needs the access scope until replacement or close.
            } catch {
                log.warning("Quick Look bookmark resolve failed: \(String(describing: error), privacy: .public)")
            }

        case .clipboardImage(let filename):
            if let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first {
                let url = appSupport
                    .appendingPathComponent("Shelf", isDirectory: true)
                    .appendingPathComponent("clipboard-images", isDirectory: true)
                    .appendingPathComponent(filename)
                quickLook.show(urls: [url])
            }

        case .webURL, .text:
            log.debug("Quick Look skipped for non-file item kind")
        }
    }

    private func handleDragOutEnded(_ result: DragOutResult, fromShelf shelfID: ShelfGroupID) {
        let operation = result.operation
        let itemID = result.itemID

        if operation.isEmpty {
            log.debug("Drag-out cancelled for item id=\(itemID.rawValue.uuidString, privacy: .public)")
            return
        }

        guard let shelf = shelfStore.get(shelfID: shelfID) else {
            log.warning("Drag-out: shelf id=\(shelfID.rawValue.uuidString, privacy: .public) not found in store")
            return
        }
        guard let item = shelf.items.first(where: { $0.id == itemID }) else {
            log.warning("Drag-out: item id=\(itemID.rawValue.uuidString, privacy: .public) not found in shelf")
            return
        }

        let isConfirmedMove = result.promiseAttempted && result.promiseSucceeded

        if isConfirmedMove {
            deleteOriginalFile(for: item)
            shelfStore.update(shelfID: shelfID) { shelf in
                shelf.items.removeAll { $0.id == itemID }
                shelf.lastUsedAt = Date()
            }
            if let updated = shelfStore.get(shelfID: shelfID),
               let viewModel = viewModels[shelfID] {
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

    private func handleMultiDragOutEnded(_ result: MultiDragOutResult, fromShelf shelfID: ShelfGroupID) {
        guard !result.operation.isEmpty else {
            log.debug("Multi drag-out cancelled for shelf id=\(shelfID.rawValue.uuidString, privacy: .public)")
            return
        }
        guard let shelf = shelfStore.get(shelfID: shelfID) else {
            log.warning("Multi drag-out: shelf id=\(shelfID.rawValue.uuidString, privacy: .public) not found in store")
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
        shelfStore.update(shelfID: shelfID) { shelf in
            shelf.items.removeAll { confirmedIDs.contains($0.id) }
            shelf.lastUsedAt = Date()
        }
        if let updated = shelfStore.get(shelfID: shelfID),
           let viewModel = viewModels[shelfID] {
            if updated.items.isEmpty {
                viewModel.isExpanded = false
            }
            viewModel.reload(from: updated)
        }
        log.info("Multi drag-out removed \(confirmedIDs.count, privacy: .public) confirmed item(s) from shelf id=\(shelfID.rawValue.uuidString, privacy: .public)")
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
        for shelf in shelfStore.all() {
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
