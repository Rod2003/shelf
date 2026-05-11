// Pasteboard → ShelfItem conversion.
//
// `DragItemFactory` is the pure conversion layer between `NSPasteboard`
// (an AppKit type) and `[ShelfItem]` (a ShelfCore value type). It
// encapsulates the precedence rule (file URL > web URL > image > text),
// security-scoped bookmark creation, and clipboard-image persistence.
// Every public surface is `static` because the factory holds no state.
//
// Pasteboard precedence (highest first):
//   1. `.fileURL`           → `.fileBookmark` (security-scoped if available)
//   2. web URL via `.URL`   → `.webURL`
//   3. image data           → `.clipboardImage` (PNG written to App Support)
//   4. `.string`            → `.text`
//
// Folders are stored as a single `.fileBookmark` item (not expanded).
// Symlinks are stored as-is. The factory makes zero outbound network calls.
//
// ## Application Support persistence
//
// Clipboard images are written to:
//   `~/Library/Application Support/Shelf/clipboard-images/`
// The directory is created on demand.
//
// ## Security-scoped bookmarks
//
// File URL items use `URL.bookmarkData(options: [.withSecurityScope], ...)`.
// Outside of a sandbox the option is a no-op (the resulting Data still
// resolves correctly), but it is forward-compat for the day Shelf opts into
// the App Sandbox. Resolving these bookmarks is the responsibility of the
// `BookmarkResolver`.

import AppKit
import Foundation
import OSLog
import ShelfCore

/// Stateless converter from `NSPasteboard` contents to `[ShelfItem]`.
///
/// Use the single entry point `makeItems(from:)`. All other methods are
/// implementation detail and intentionally `private`.
@MainActor
public enum DragItemFactory {
    private static let log = Logger(subsystem: "dev.rod.shelf", category: "drag")

    /// Maximum length for a `displayName` derived from a body of text or a
    /// long URL. 80 chars is comfortable for a single-line table cell at the
    /// shelf's default 360pt width.
    private static let maxDisplayNameLength: Int = 80

    /// Convert a pasteboard's contents into ShelfItems by precedence:
    ///
    ///   `.fileURL` > web URL > image data > `.string`
    ///
    /// - Folders are stored as a single `.fileBookmark` item (no expansion).
    /// - Multiple file URLs in one drop produce multiple items.
    /// - Multiple web URLs in one drop produce multiple items.
    /// - Image and text drops produce at most one item per drop.
    ///
    /// Returns an empty array if no acceptable content is present or if all
    /// extraction attempts failed (e.g. bookmark creation threw, image PNG
    /// encoding failed). Errors are logged via OSLog at `error` level.
    public static func makeItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        // 1. File URLs (highest precedence — even when .string is also present,
        //    e.g. Safari often offers both for a link drag of a downloaded file).
        if let urls = readFileURLs(from: pasteboard), !urls.isEmpty {
            let items = urls.compactMap { makeFileBookmarkItem(from: $0) }
            log.info("makeItems: \(items.count, privacy: .public) fileBookmark item(s) from \(urls.count, privacy: .public) URL(s)")
            return items
        }

        // 2. Web URLs (browsers, link drags, address-bar favicon drags).
        if let webURLs = readWebURLs(from: pasteboard), !webURLs.isEmpty {
            let items = webURLs.map(makeWebURLItem(from:))
            log.info("makeItems: \(items.count, privacy: .public) webURL item(s)")
            return items
        }

        // 3. Image data (Preview, screenshots, copy-image-from-browser, etc.).
        if let image = readImage(from: pasteboard) {
            if let item = makeClipboardImageItem(from: image) {
                log.info("makeItems: 1 clipboardImage item")
                return [item]
            }
            return []
        }

        // 4. Plain text (TextEdit selections, terminal selections, anything
        //    that promotes only `.string`).
        if let text = readText(from: pasteboard), !text.isEmpty {
            log.info("makeItems: 1 text item (length=\(text.count, privacy: .public))")
            return [makeTextItem(text: text)]
        }

        log.debug("makeItems: pasteboard advertised no extractable content")
        return []
    }

    // MARK: Pasteboard readers

    /// Read file URLs from the pasteboard, filtering to local file URLs only.
    /// Uses `.urlReadingFileURLsOnly: true` so a web URL on the pasteboard
    /// does not accidentally satisfy this branch.
    private static func readFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let raw = pasteboard.readObjects(forClasses: [NSURL.self], options: opts) else {
            return nil
        }
        let urls = raw.compactMap { $0 as? URL }.filter { $0.isFileURL }
        return urls.isEmpty ? nil : urls
    }

    /// Read web URLs from the pasteboard, filtering to non-file URLs whose
    /// scheme starts with `http` (covers `http`, `https`).
    ///
    /// We deliberately do NOT call `readObjects(forClasses:options:)` with
    /// `.urlReadingFileURLsOnly: false` — without that option, the API returns
    /// both file and web URLs, and we already handled file URLs in the prior
    /// step. Filtering to `!isFileURL` here is correct.
    private static func readWebURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let raw = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) else {
            return nil
        }
        let urls = raw
            .compactMap { $0 as? URL }
            .filter { url in
                guard !url.isFileURL else { return false }
                guard let scheme = url.scheme?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
        return urls.isEmpty ? nil : urls
    }

    /// Read the first image present on the pasteboard.
    private static func readImage(from pasteboard: NSPasteboard) -> NSImage? {
        guard let raw = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) else {
            return nil
        }
        return raw.compactMap { $0 as? NSImage }.first
    }

    /// Read plain text from the pasteboard.
    private static func readText(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)
    }

    // MARK: Item builders

    /// Build a `.fileBookmark` item by creating a security-scoped bookmark
    /// to the file's **existing location**. The file is NOT moved or copied;
    /// the shelf just holds a reference to it. This is the standard shelf
    /// model (matches Dropover): your originals stay where you put them.
    ///
    /// Outside of a sandbox `.withSecurityScope` is a no-op
    /// (`startAccessingSecurityScopedResource` returns true and is a no-op),
    /// but the bookmark is still produced — this future-proofs the persisted
    /// shape against a future sandbox migration.
    ///
    /// Returns `nil` (and logs at `error` level) if bookmark creation throws.
    /// Folders, symlinks, and aliases are treated identically — no expansion,
    /// no resolution.
    private static func makeFileBookmarkItem(from url: URL) -> ShelfItem? {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let record = BookmarkRecord(bookmarkData: data, originalPath: url.path)
            let displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            return ShelfItem(kind: .fileBookmark(record), displayName: displayName)
        } catch {
            log.error("Failed to create bookmark for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Build a `.webURL` item. `displayName` prefers the host (truncated to
    /// `maxDisplayNameLength`) so the cell shows "github.com" rather than
    /// "https://github.com/anthropics/...". If host is `nil` (e.g. a `mailto:`
    /// or other non-network URL — although `readWebURLs` filters those out)
    /// the absolute string is used as a fallback.
    private static func makeWebURLItem(from url: URL) -> ShelfItem {
        let raw = url.host ?? url.absoluteString
        let displayName = String(raw.prefix(maxDisplayNameLength))
        return ShelfItem(kind: .webURL(url), displayName: displayName)
    }

    /// Build a `.text` item. `displayName` is the trimmed first 60 chars of
    /// the text — enough to identify the item in the shelf list without
    /// blowing out the cell.
    private static func makeTextItem(text: String) -> ShelfItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = String(trimmed.prefix(60))
        return ShelfItem(kind: .text(text), displayName: display)
    }

    /// Build a `.clipboardImage` item by writing the image as PNG to
    /// Application Support and storing only the filename in the item.
    ///
    /// Filename format: `Image-{ISO8601 with `:` → `-`}-{8 char UUID}.png`.
    /// The first segment makes images chronologically sortable in Finder; the
    /// short UUID guarantees uniqueness when many drops happen within a
    /// second.
    ///
    /// Returns `nil` (and logs `error`) if Application Support is unreachable,
    /// directory creation throws, PNG encoding fails, or the write fails.
    private static func makeClipboardImageItem(from image: NSImage) -> ShelfItem? {
        guard let directory = clipboardImagesDirectory() else { return nil }

        let filename = generateClipboardImageFilename()
        let dest = directory.appendingPathComponent(filename)

        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            log.error("Failed to encode clipboard image as PNG (size=\(image.size.width, privacy: .public)x\(image.size.height, privacy: .public))")
            return nil
        }

        do {
            try png.write(to: dest, options: .atomic)
        } catch {
            log.error("Failed to write clipboard image to \(dest.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }

        return ShelfItem(kind: .clipboardImage(filename: filename), displayName: filename)
    }

    /// Compute the on-disk directory used for clipboard image storage.
    ///
    /// Path: `~/Library/Application Support/Shelf/clipboard-images/`.
    /// Created on demand. Returns `nil` only if Application Support is
    /// unreachable (e.g. a heavily restricted environment where
    /// `FileManager.urls(for:in:)` returns empty).
    private static func clipboardImagesDirectory() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log.error("Application Support directory unreachable")
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("Shelf", isDirectory: true)
            .appendingPathComponent("clipboard-images", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            log.error("Failed to create clipboard images directory at \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Generate a filename of the form `Image-{ts}-{uuid8}.png` where `{ts}`
    /// is an ISO8601 timestamp with `:` replaced by `-` (NTFS/HFS compatible)
    /// and `{uuid8}` is the first 8 chars of a UUID for collision resistance.
    private static func generateClipboardImageFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uuid = UUID().uuidString.prefix(8)
        return "Image-\(timestamp)-\(uuid).png"
    }
}
