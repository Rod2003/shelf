import AppKit
import ShelfCore
import QuickLookThumbnailing
import OSLog
public actor ThumbnailService {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")
    private var cache: [String: NSImage] = [:]
    private let maxCacheCount: Int

    public init(maxCacheCount: Int = 200) {
        self.maxCacheCount = maxCacheCount
    }
    public func thumbnail(
        for url: URL,
        size: CGSize = CGSize(width: 96, height: 96),
        scale: CGFloat = 2
    ) async -> NSImage? {
        let key = "\(url.path)-\(Int(size.width))x\(Int(size.height))-\(Int(scale))"
        if let cached = cache[key] { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return storeCachedThumbnail(representation.nsImage, forKey: key)
        } catch {
            if let image = Self.sourceImageIfAvailable(for: url) {
                return storeCachedThumbnail(image, forKey: key)
            }
            log.warning("Thumbnail generation failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func thumbnail(
        for item: ShelfItem,
        resolver: BookmarkResolver?,
        size: CGSize = CGSize(width: 96, height: 96),
        scale: CGFloat = 2
    ) async -> NSImage? {
        switch item.kind {
        case .fileBookmark(let record):
            guard let resolver else { return nil }
            do {
                let resolution = try resolver.resolve(record)
                defer { resolver.release(resolution.url) }
                return await thumbnail(for: resolution.url, size: size, scale: scale)
            } catch {
                return nil
            }
        case .clipboardImage(let filename):
            guard let url = DefaultsBackend.clipboardImageURL(filename: filename) else { return nil }
            return await thumbnail(for: url, size: size, scale: scale)
        case .webURL, .text:
            return nil
        }
    }

    public func clearCache() {
        cache.removeAll()
    }

    private func storeCachedThumbnail(_ image: NSImage, forKey key: String) -> NSImage {
        if cache.count >= maxCacheCount { cache.removeAll() }
        cache[key] = image
        return image
    }

    public nonisolated static func sourceImageIfAvailable(for url: URL) -> NSImage? {
        guard
            let image = NSImage(contentsOf: url),
            image.size.width > 0,
            image.size.height > 0
        else {
            return nil
        }
        return image
    }
}
