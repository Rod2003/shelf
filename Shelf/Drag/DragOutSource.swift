// Shelf — drag-OUT source (T14).
//
// `DragOutSource` is the `NSDraggingSource` implementation that ShelfItemView
// (or its NSView wrapper, T18) hands to `NSView.beginDraggingSession(...)` to
// initiate a drag from the shelf onto another app, Finder, or the desktop.
//
// Responsibilities:
//   • Build the right pasteboard writer for a `ShelfItem`:
//     - `.fileBookmark`     → `NSFilePromiseProvider` (lazy file copy via `FilePromiseDelegate`)
//     - `.clipboardImage`   → `NSFilePromiseProvider` (image lives in App Support; promise resolves it)
//     - `.webURL`           → `NSPasteboardItem` with `.URL` + `.string`
//     - `.text`             → `NSPasteboardItem` with `.string`
//   • Vend the standard `NSDraggingSource` operation mask (`.copy` for
//     out-of-app drops; system-driven Option-modifier converts to `.move`
//     where applicable). We do NOT implement copy-vs-move plumbing in v1 —
//     macOS handles it via the modifier-driven mask.
//
// Lifecycle:
//   • `DragOutSource` and `FilePromiseDelegate` are created once per
//     ShelfWindowController (or once globally — both work). The same
//     instance can serve many drags.
//   • Each drag registers its `ShelfItem` snapshot in
//     `FilePromiseDelegate.pendingItems` keyed by the item's UUID; the
//     `NSFilePromiseProvider.userInfo["itemID"]` carries the lookup key
//     across into AppKit's drag machinery.
//
// This file does NOT modify `ShelfItemView` or wire drag-out into SwiftUI.
// T18 owns the integration: it constructs an `NSView` carrier, calls
// `makePasteboardWriter(for:)` on `mouseDown`, and invokes
// `beginDraggingSession(with:event:source:)`.

import AppKit
import Foundation
import OSLog
import ShelfCore
import UniformTypeIdentifiers

/// `NSDraggingSource` that builds pasteboard writers for ShelfItems.
///
/// Files (and clipboard-image items) are vended as lazy
/// `NSFilePromiseProvider`s; web URLs and plain text are vended as
/// `NSPasteboardItem` so they don't pay the file-promise dance just to drop
/// a string somewhere.
@MainActor
public final class DragOutSource: NSObject, NSDraggingSource {

    private let log = Logger(subsystem: "dev.rod.shelf", category: "drag")
    private let promiseDelegate: FilePromiseDelegate

    public init(promiseDelegate: FilePromiseDelegate) {
        self.promiseDelegate = promiseDelegate
        super.init()
    }

    /// Convenience initializer that creates a fresh `FilePromiseDelegate`
    /// (with a default `BookmarkResolver`) — useful for ad-hoc construction
    /// at NSView wrapper points where the caller doesn't already own a
    /// delegate. Tests / T18 may pass their own delegate via
    /// `init(promiseDelegate:)` for instrumentation.
    public override convenience init() {
        self.init(promiseDelegate: FilePromiseDelegate())
    }

    /// Build the pasteboard-writing object for a single `ShelfItem`.
    ///
    /// For file-style items (`.fileBookmark`, `.clipboardImage`) returns an
    /// `NSFilePromiseProvider` with this source's `FilePromiseDelegate` and
    /// registers the item snapshot in
    /// `FilePromiseDelegate.pendingItems` so the on-demand write can find it.
    ///
    /// For web URL items returns an `NSPasteboardItem` advertising both
    /// `.URL` and `.string` (so Safari, TextEdit, etc. each find a flavor
    /// they understand).
    ///
    /// For plain-text items returns an `NSPasteboardItem` advertising
    /// `.string` only.
    ///
    /// Returns `nil` only if the item kind is unrecognized — currently
    /// unreachable because `ShelfItemKind` is an exhaustively-matched
    /// `enum`, but the optional return is preserved for forward
    /// compatibility (e.g. a future `.richText` kind).
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

    /// Best-effort UTI for the given item. For `.fileBookmark` we try the
    /// path extension via `UTType(filenameExtension:)` and fall back to
    /// `public.data` when the extension is missing or unmappable. For
    /// `.clipboardImage` we declare PNG (the canonical format `DragItemFactory`
    /// writes for clipboard images).
    private func uti(for item: ShelfItem) -> String? {
        switch item.kind {
        case .fileBookmark(let record):
            let ext = (record.originalPath as NSString).pathExtension
            if ext.isEmpty { return UTType.data.identifier }
            return UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
        case .clipboardImage:
            return UTType.png.identifier
        case .webURL, .text:
            return nil
        }
    }

    // MARK: NSDraggingSource

    /// Operation mask for the dragging session. Outside the app we vend
    /// `[.copy, .generic]` (e.g. dragging into Finder copies the file by
    /// default; Option-drag promotes to move). Inside the app we additionally
    /// allow `.move` so a future T22-style "rearrange items" gesture can be
    /// hooked here without changing this surface.
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

    /// Logged for diagnostics. We do NOT alter ShelfStore here on
    /// successful drag-out — the spec explicitly notes that drag-out
    /// preserves the source item (no implicit removal).
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        log.info("Drag-out session ended op=\(operation.rawValue, privacy: .public) at=(\(screenPoint.x, privacy: .public),\(screenPoint.y, privacy: .public))")
    }
}
