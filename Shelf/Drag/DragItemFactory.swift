import AppKit
import Foundation
import OSLog
import ShelfCore

@MainActor
public enum DragItemFactory {
    private static let log = Logger(subsystem: "dev.rod.shelf", category: "drag")

    private static let maxDisplayNameLength: Int = 80

    public static func makeItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        // File URLs must win over `.string`; Safari-style drags often publish both.
        if let urls = readFileURLs(from: pasteboard), !urls.isEmpty {
            let items = urls.compactMap { makeFileBookmarkItem(from: $0) }
            log.info("makeItems: \(items.count, privacy: .public) fileBookmark item(s) from \(urls.count, privacy: .public) URL(s)")
            return items
        }

        if let webURLs = readWebURLs(from: pasteboard), !webURLs.isEmpty {
            let items = webURLs.map(makeWebURLItem(from:))
            log.info("makeItems: \(items.count, privacy: .public) webURL item(s)")
            return items
        }

        if let image = readImage(from: pasteboard) {
            if let item = makeClipboardImageItem(from: image) {
                log.info("makeItems: 1 clipboardImage item")
                return [item]
            }
            return []
        }

        if let text = readText(from: pasteboard), !text.isEmpty {
            log.info("makeItems: 1 text item (length=\(text.count, privacy: .public))")
            return [makeTextItem(text: text)]
        }

        log.debug("makeItems: pasteboard advertised no extractable content")
        return []
    }

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

    private static func readImage(from pasteboard: NSPasteboard) -> NSImage? {
        guard let raw = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) else {
            return nil
        }
        return raw.compactMap { $0 as? NSImage }.first
    }

    private static func readText(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)
    }

    private static func makeFileBookmarkItem(from url: URL) -> ShelfItem? {
        do {
            // Persist sandbox-ready bookmarks; do not copy source files into Shelf.
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

    private static func makeWebURLItem(from url: URL) -> ShelfItem {
        let raw = url.host ?? url.absoluteString
        let displayName = String(raw.prefix(maxDisplayNameLength))
        return ShelfItem(kind: .webURL(url), displayName: displayName)
    }

    private static func makeTextItem(text: String) -> ShelfItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = String(trimmed.prefix(60))
        return ShelfItem(kind: .text(text), displayName: display)
    }

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

    private static func generateClipboardImageFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uuid = UUID().uuidString.prefix(8)
        return "Image-\(timestamp)-\(uuid).png"
    }
}
