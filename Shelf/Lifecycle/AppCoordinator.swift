// App Coordinator — single composition root for the Shelf app.
//
// `AppCoordinator` instantiates every standalone controller and wires them
// together via the public callback closures each controller exposes for
// late binding. AppDelegate constructs exactly one `AppCoordinator` in
// `applicationDidFinishLaunching` and tears it down in
// `applicationWillTerminate`.
//
// Responsibilities:
//   • Persistence: own one `DefaultsBackend` + `ShelfStore` for the app's
//     lifetime. Ensure `~/Library/Application Support/Shelf/...` exists on
//     first launch.
//   • Activation: own one `HotkeyManager`, one `ShakeDetector`, one
//     `MenuBarController`. Wire callbacks for new-shelf / Esc / Space /
//     shake / menu activation. Gate Esc + Space on shelf focus.
//   • Presentation: own one `ShelfWindowManager`, one `ThumbnailService`,
//     one `QuickLookCoordinator`. Construct one `ShelfViewModel` per open
//     shelf, plumb store mutations through to the view model.
//   • Drag-out machinery: own one shared `FilePromiseDelegate` +
//     `DragOutSource`.
//
// Threading: `@MainActor`. All controllers are `@MainActor` or otherwise
// main-thread-safe. `ShelfStore.onChange` may fire from any thread, so we
// hop to MainActor explicitly before touching any view-side state from
// inside that callback.

import AppKit
import OSLog
import ShelfCore

/// Composition root for the Shelf app — owns every controller and wires
/// them into a coherent runtime via public callback closures.
@MainActor
public final class AppCoordinator {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")

    // MARK: Persistence

    private let defaultsBackend: DefaultsBackend
    private let shelfStore: ShelfStore
    private let bookmarkResolver: BookmarkResolver

    // MARK: Activation

    private let hotkeyManager: HotkeyManager
    private let shakeDetector: ShakeDetector
    private let menuBar: MenuBarController

    // MARK: Presentation

    private let windowManager: ShelfWindowManager
    private let thumbnailService: ThumbnailService
    private let quickLook: QuickLookCoordinator

    // MARK: Drag-out machinery (one shared instance for the app lifetime)

    private let promiseDelegate: FilePromiseDelegate
    private let dragOutSource: DragOutSource

    // MARK: Per-shelf state

    /// View models keyed by `ShelfID` so we can refresh them in place when
    /// `ShelfStore` mutations fire `onChange`.
    private var viewModels: [ShelfID: ShelfViewModel] = [:]

    // MARK: Lifecycle

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

    /// Wire callbacks, ensure App Support tree, sweep orphaned managed
    /// files, and start the shake detector.
    /// Idempotent? No — call exactly once per app launch.
    public func bootstrap() {
        defaultsBackend.ensureApplicationSupport()
        wireCallbacks()
        sweepOrphanedManagedFiles()
        shakeDetector.start()
        log.info("AppCoordinator bootstrapped")
    }

    /// Stop background work and close any open panels. Called from
    /// `AppDelegate.applicationWillTerminate`. Carbon hotkey unregistration
    /// happens in `HotkeyManager.deinit`, which fires when this coordinator
    /// is released after AppDelegate drops its strong reference.
    public func teardown() {
        shakeDetector.stop()
        windowManager.closeAll()
        log.info("AppCoordinator teardown")
    }

    // MARK: Wiring

    private func wireCallbacks() {
        // ⌘⇧Space → new shelf at the cursor location.
        hotkeyManager.onNewShelf = { [weak self] in
            self?.createNewShelfAtCursor()
        }
        // Esc → close the currently-key shelf. Gated by `setEscEnabled`
        // below — if no shelf is key, the hotkey is unregistered entirely
        // so this closure never fires (defensive guard kept for clarity).
        hotkeyManager.onCloseFrontmost = { [weak self] in
            guard let self else { return }
            guard let id = self.windowManager.currentlyKeyShelf() else { return }
            self.windowManager.closeShelf(id)
        }
        // Space → Quick Look on the selected item of the currently-key
        // shelf. Gated by `setSpaceEnabled` (CRITICAL: never globally
        // active — would steal Space from every app).
        hotkeyManager.onQuickLook = { [weak self] in
            self?.invokeQuickLookForKeyShelf()
        }

        // Shake during drag → new shelf at the cursor — same path as the
        // hotkey, so the user gets identical placement semantics.
        shakeDetector.onShakeDuringDrag = { [weak self] _ in
            self?.createNewShelfAtCursor()
        }

        // Menu bar callbacks.
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

        // Window-manager focus changes → toggle context-sensitive hotkeys.
        // We enable Esc and Space when ANY shelf becomes key; disable when
        // no shelf is key. Per HotkeyManager docstrings: registering bare
        // Space globally would steal every Space press in every app, so
        // gating MUST be conservative.
        windowManager.onShelfBecameKey = { [weak self] _ in
            guard let self else { return }
            self.hotkeyManager.setEscEnabled(true)
            self.hotkeyManager.setSpaceEnabled(true)
        }
        windowManager.onShelfResignedKey = { [weak self] _ in
            guard let self else { return }
            // Defer the disable until we confirm NO shelf is currently
            // key — otherwise switching focus between two open shelves
            // would briefly disable the hotkey only for it to be
            // re-enabled by the next becomeKey.
            if self.windowManager.currentlyKeyShelf() == nil {
                self.hotkeyManager.setEscEnabled(false)
                self.hotkeyManager.setSpaceEnabled(false)
            }
        }
        windowManager.onShelfClosed = { [weak self] id in
            self?.viewModels.removeValue(forKey: id)
            self?.publishActiveShelvesToMenu()
        }

        // Store changes (item add/remove, shelf create/replace) refresh the
        // Active-Shelves submenu so file lists stay current. ShelfStore.onChange
        // may fire off the main thread, so we hop to MainActor explicitly.
        shelfStore.onChange = { [weak self] in
            Task { @MainActor in
                self?.publishActiveShelvesToMenu()
            }
        }
    }

    // MARK: High-level actions

    /// Create a brand-new shelf, persist it, and open a panel anchored at
    /// the cursor. Triggered by ⌘⇧Space, the menu bar's "New Shelf" item,
    /// and the shake-during-drag detector.
    private func createNewShelfAtCursor() {
        let shelf = Shelf(name: "")
        shelfStore.add(shelf)
        let viewModel = ShelfViewModel(shelf: shelf)
        viewModels[shelf.id] = viewModel
        let shelfID = shelf.id
        let contentView = ContentViewFactory.makeContentView(
            viewModel: viewModel,
            resolver: bookmarkResolver,
            thumbnailService: thumbnailService,
            onDragEnded: { [weak self] result in
                self?.handleDragOutEnded(result, fromShelf: shelfID)
            },
            onClose: { [weak self] in
                self?.windowManager.closeShelf(shelfID)
            }
        )
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

    /// Install a `DragInView` on the wrapper produced by
    /// `ContentViewFactory.makeContentView(...)` so drops onto the shelf
    /// area are accepted. The factory wraps an `NSHostingView` in a plain
    /// `NSView`; we add the drag receiver as a sibling beneath the hosting
    /// view, since AppKit's drag-destination search picks the topmost
    /// REGISTERED subview (per Apple docs on `NSDraggingDestination`).
    /// Putting it below the hosting view also preserves SwiftUI tap
    /// gestures on the cells.
    private func wireDragIn(on contentView: NSView, for shelfID: ShelfID) {
        let dragIn = DragInView(frame: contentView.bounds)
        dragIn.autoresizingMask = [.width, .height]
        dragIn.onDrop = { [weak self] items in
            self?.appendItems(items, to: shelfID)
        }
        // Position below the existing hosting subview so tap gestures keep
        // reaching SwiftUI cells while drag-IN routes to DragInView (the
        // only registered drag destination in the hierarchy).
        contentView.addSubview(
            dragIn,
            positioned: .below,
            relativeTo: contentView.subviews.first
        )
    }

    /// Persist a successful drop onto the given shelf and refresh the
    /// view model so the panel updates immediately. Also bumps
    /// `lastUsedAt` so the shelf's recency is accurate.
    private func appendItems(_ items: [ShelfItem], to shelfID: ShelfID) {
        shelfStore.update(shelfID: shelfID) { shelf in
            shelf.items.append(contentsOf: items)
            shelf.lastUsedAt = Date()
        }
        if let updated = shelfStore.get(shelfID: shelfID),
           let viewModel = viewModels[shelfID] {
            viewModel.reload(from: updated)
        }
        log.info("Appended \(items.count, privacy: .public) item(s) to shelf id=\(shelfID.rawValue.uuidString, privacy: .public)")
    }

    /// Open Quick Look for the selected item of the currently-key shelf,
    /// or the first item if nothing is selected. Non-file kinds
    /// (`.webURL`, `.text`) are no-ops.
    ///
    /// Each guard logs at debug level so a Console trace makes the failing
    /// link obvious — this method previously failed silently when invoked
    /// before the user had tapped a cell, which was indistinguishable from
    /// the hotkey not firing at all.
    private func invokeQuickLookForKeyShelf() {
        guard let id = windowManager.currentlyKeyShelf() else {
            log.debug("Quick Look skipped: no key shelf")
            return
        }
        guard let viewModel = viewModels[id] else {
            log.debug("Quick Look skipped: no view model for shelf id=\(id.rawValue.uuidString, privacy: .public)")
            return
        }
        // Fall back to the first item when nothing is selected so the user
        // can press Space immediately after summoning a shelf without first
        // tapping a cell. Selection-by-tap still wins when present.
        let targetItem: ShelfItem? =
            viewModel.selectedItemID
                .flatMap { selected in viewModel.items.first(where: { $0.id == selected }) }
                ?? viewModel.items.first
        guard let item = targetItem else {
            log.debug("Quick Look skipped: shelf id=\(id.rawValue.uuidString, privacy: .public) has no items")
            return
        }

        switch item.kind {
        case .fileBookmark(let record):
            do {
                let resolution = try bookmarkResolver.resolve(record)
                quickLook.show(urls: [resolution.url])
                // We intentionally do not pair release(_:) here because
                // QuickLook holds the URL across the life of the panel;
                // the access scope is needed for as long as the user
                // browses. The next QL show or panel close releases.
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

    // MARK: Drag-out completion (MOVE / COPY semantics from receiver)

    /// Called by `DragOutCellWrapper` after the system finishes the drag
    /// session and reports the receiver's chosen `NSDragOperation`.
    ///
    /// Shelf treats drag-out as **MOVE only on positively-confirmed
    /// transfers**. The only path that gives us a real success signal is
    /// the file-promise protocol (`NSFilePromiseProvider.writePromiseTo`):
    /// we get a callback when the receiver actually pulled the bytes.
    ///
    /// Two destination paths exist depending on which pasteboard type
    /// the receiver chose to read:
    ///
    /// 1. **File-promise path** (Finder, native promise-aware apps) —
    ///    AppKit invoked `writePromiseTo`. `promiseAttempted=true`.
    ///    If `promiseSucceeded=true`, we honor MOVE semantics: delete
    ///    the original and remove the cell. If `promiseSucceeded=false`,
    ///    the copy threw mid-write and we MUST keep the original to
    ///    avoid destroying the user's sole copy of the bytes.
    /// 2. **`.fileURL` direct-read path** (browsers, Slack, Discord,
    ///    Messages, web upload zones, anything that doesn't speak the
    ///    file-promise protocol) — receiver read the URL string from
    ///    the pasteboard and decided what to do on its own.
    ///    `promiseAttempted=false`. We have NO confirmation here:
    ///    - The OS-level drag may have completed but the receiver's
    ///      *application-level* validation can fail asynchronously
    ///      (e.g., GitHub rejecting an upload over its size limit
    ///      AFTER bytes were transferred), and we'd never know.
    ///    - The receiver may have read the URL string and ignored it.
    ///    Auto-deleting in either case is data loss. So we keep both
    ///    the original on disk AND the shelf cell, allowing the user
    ///    to retry from the same cell if their upload failed.
    ///
    /// Operation semantics (`.move`/`.copy`/etc.) are informational only;
    /// they do not influence the deletion decision. The OS reports `.copy`
    /// for any cross-volume Finder drop and for every browser drop alike,
    /// so the operation flag cannot distinguish "succeeded" from "failed
    /// after upload."
    private func handleDragOutEnded(_ result: DragOutResult, fromShelf shelfID: ShelfID) {
        let operation = result.operation
        let itemID = result.itemID

        // Cancelled drop: receiver chose nothing or rejected. Leave the
        // shelf and the source file untouched.
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

    /// Delete the original file referenced by `item` after a successful
    /// `.move` drag-out. Best-effort — failure is logged but doesn't roll
    /// back the shelf-side removal (the user's intent was MOVE; if the
    /// delete fails they'll just have a leftover at the source).
    private func deleteOriginalFile(for item: ShelfItem) {
        switch item.kind {
        case .fileBookmark(let record):
            do {
                let resolution = try bookmarkResolver.resolve(record)
                try FileManager.default.removeItem(at: resolution.url)
                // Don't `release(_:)` — the URL no longer exists. The
                // security-scoped access is implicitly torn down with the
                // file.
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
            // Inline data — no original file to delete.
            break
        }
    }

    /// Best-effort orphan sweep, called once per launch from `bootstrap()`.
    ///
    /// Walks every directory in `~/Library/Application Support/Shelf/items/`
    /// and `~/Library/Application Support/Shelf/clipboard-images/`, then
    /// deletes anything not referenced by a current shelf. This is how we
    /// reclaim disk for items that were dragged out (drop-receivers got the
    /// file but the source persisted) or evicted from the recent-cap.
    ///
    /// Runs synchronously (the directories are small — bounded by 5 shelves
    /// × handful of items each) but errors are swallowed to keep launch
    /// resilient against permission edge cases.
    private func sweepOrphanedManagedFiles() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let shelfBase = appSupport.appendingPathComponent("Shelf", isDirectory: true)
        let itemsDir = shelfBase.appendingPathComponent("items", isDirectory: true)
        let clipboardDir = shelfBase.appendingPathComponent("clipboard-images", isDirectory: true)

        // Build the live reference set across every shelf the store knows about.
        var liveItemDirs: Set<String> = []      // ItemID UUID strings
        var liveClipboardFiles: Set<String> = []  // filenames
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

        // Sweep `items/` — each subdirectory is named by its ItemID UUID.
        if let entries = try? fm.contentsOfDirectory(at: itemsDir, includingPropertiesForKeys: nil) {
            for entry in entries where !liveItemDirs.contains(entry.lastPathComponent) {
                try? fm.removeItem(at: entry)
                log.info("Swept orphaned item directory \(entry.lastPathComponent, privacy: .public)")
            }
        }

        // Sweep `clipboard-images/` — flat filenames.
        if let entries = try? fm.contentsOfDirectory(at: clipboardDir, includingPropertiesForKeys: nil) {
            for entry in entries where !liveClipboardFiles.contains(entry.lastPathComponent) {
                try? fm.removeItem(at: entry)
                log.info("Swept orphaned clipboard image \(entry.lastPathComponent, privacy: .public)")
            }
        }
    }
}
