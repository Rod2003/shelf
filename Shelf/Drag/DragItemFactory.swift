import AppKit
import Foundation
import OSLog
import ShelfCore
import UniformTypeIdentifiers

@MainActor
public enum DragItemFactory {
    private static let log = Logger(subsystem: "dev.rod.shelf", category: "drag")

    private static let maxDisplayNameLength: Int = 80
    public static let acceptedPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .png,
        .tiff,
        .fileContents,
        NSPasteboard.PasteboardType("public.image"),
        .string
    ]
    public static let acceptedContentTypes: [UTType] = [
        .fileURL,
        .url,
        .png,
        .tiff,
        .image,
        .plainText,
        .text
    ]

    public static func makeItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        // File URLs must win over `.string`; Safari-style drags often publish both.
        if let urls = readFileURLs(from: pasteboard), !urls.isEmpty {
            let items = urls.compactMap { DropItemBuilder.makeFileBookmarkItem(from: $0) }
            log.info("makeItems: \(items.count, privacy: .public) fileBookmark item(s) from \(urls.count, privacy: .public) URL(s)")
            return items
        }

        if let webURLs = readWebURLs(from: pasteboard), !webURLs.isEmpty {
            let items = webURLs.map(DropItemBuilder.makeWebURLItem(from:))
            log.info("makeItems: \(items.count, privacy: .public) webURL item(s)")
            return items
        }

        if let image = readImage(from: pasteboard) {
            if let item = DropItemBuilder.makeClipboardImageItem(from: image) {
                log.info("makeItems: 1 clipboardImage item")
                return [item]
            }
            return []
        }

        if let text = readText(from: pasteboard), !text.isEmpty {
            log.info("makeItems: 1 text item (length=\(text.count, privacy: .public))")
            return [DropItemBuilder.makeTextItem(text: text)]
        }

        log.debug("makeItems: pasteboard advertised no extractable content")
        return []
    }

    public static func makeItems(from providers: [NSItemProvider]) async -> [ShelfItem] {
        if let urls = await readFileURLs(from: providers), !urls.isEmpty {
            let items = urls.compactMap { DropItemBuilder.makeFileBookmarkItem(from: $0) }
            log.info("makeItems: \(items.count, privacy: .public) fileBookmark item(s) from SwiftUI drop")
            return items
        }

        if let urls = await readWebURLs(from: providers), !urls.isEmpty {
            let items = urls.map(DropItemBuilder.makeWebURLItem(from:))
            log.info("makeItems: \(items.count, privacy: .public) webURL item(s) from SwiftUI drop")
            return items
        }

        if let image = await readImage(from: providers),
           let item = DropItemBuilder.makeClipboardImageItem(from: image) {
            log.info("makeItems: 1 clipboardImage item from SwiftUI drop")
            return [item]
        }

        if let text = await readText(from: providers), !text.isEmpty {
            log.info("makeItems: 1 text item from SwiftUI drop")
            return [DropItemBuilder.makeTextItem(text: text)]
        }

        log.debug("makeItems: SwiftUI drop providers advertised no extractable content")
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
}

@MainActor
enum DropItemBuilder {
    private static let log = Logger(subsystem: "dev.rod.shelf", category: "drag")
    private static let maxDisplayNameLength: Int = 80

    static func makeFileBookmarkItem(from url: URL) -> ShelfItem? {
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

    static func makeWebURLItem(from url: URL) -> ShelfItem {
        let raw = url.host ?? url.absoluteString
        let displayName = String(raw.prefix(maxDisplayNameLength))
        return ShelfItem(kind: .webURL(url), displayName: displayName)
    }

    static func makeTextItem(text: String) -> ShelfItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = String(trimmed.prefix(60))
        return ShelfItem(kind: .text(text), displayName: display)
    }

    static func makeClipboardImageItem(from image: NSImage) -> ShelfItem? {
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

private extension DragItemFactory {
    static func readFileURLs(from providers: [NSItemProvider]) async -> [URL]? {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadURL(from: provider, typeIdentifier: UTType.fileURL.identifier),
               url.isFileURL {
                urls.append(url)
            }
        }
        return urls.isEmpty ? nil : urls
    }

    static func readWebURLs(from providers: [NSItemProvider]) async -> [URL]? {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(from: provider, typeIdentifier: UTType.url.identifier),
               isWebURL(url) {
                urls.append(url)
            }
        }
        return urls.isEmpty ? nil : urls
    }

    static func readImage(from providers: [NSItemProvider]) async -> NSImage? {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self),
               let image = await loadImageObject(from: provider) {
                return image
            }
            for type in [UTType.png.identifier, UTType.tiff.identifier, UTType.image.identifier]
                where provider.hasItemConformingToTypeIdentifier(type) {
                if let data = await loadData(from: provider, typeIdentifier: type),
                   let image = NSImage(data: data) {
                    return image
                }
            }
        }
        return nil
    }

    static func readText(from providers: [NSItemProvider]) async -> String? {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self),
               let text = await loadStringObject(from: provider),
               !text.isEmpty {
                return text
            }
            for type in [UTType.plainText.identifier, UTType.text.identifier]
                where provider.hasItemConformingToTypeIdentifier(type) {
                if let text = await loadString(from: provider, typeIdentifier: type),
                   !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    static func loadURL(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        if provider.canLoadObject(ofClass: NSURL.self),
           let url = await loadURLObject(from: provider) {
            return url
        }
        guard let item = await loadItem(from: provider, typeIdentifier: typeIdentifier) else {
            return nil
        }
        return coerceURL(from: item)
    }

    static func loadURLObject(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
    }

    static func loadImageObject(from provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
    }

    static func loadStringObject(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }

    static func loadString(from provider: NSItemProvider, typeIdentifier: String) async -> String? {
        guard let item = await loadItem(from: provider, typeIdentifier: typeIdentifier) else {
            return nil
        }
        if let string = item as? String { return string }
        if let attributed = item as? NSAttributedString { return attributed.string }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        if let url = coerceURL(from: item) { return url.absoluteString }
        return nil
    }

    static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        guard let item = await loadItem(from: provider, typeIdentifier: typeIdentifier) else {
            return nil
        }
        if let data = item as? Data { return data }
        if let url = item as? URL { return try? Data(contentsOf: url) }
        if let url = item as? NSURL, let swiftURL = url as URL? { return try? Data(contentsOf: swiftURL) }
        return nil
    }

    static func loadItem(from provider: NSItemProvider, typeIdentifier: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    static func coerceURL(from item: NSSecureCoding) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let string = item as? String { return URL(string: string) }
        if let data = item as? Data {
            if let string = String(data: data, encoding: .utf8),
               let url = URL(string: string) {
                return url
            }
            return NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL
        }
        return nil
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard !url.isFileURL, let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}
