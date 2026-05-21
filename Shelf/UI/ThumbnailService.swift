import AppKit
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
        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
            let img = rep.nsImage
            if cache.count >= maxCacheCount { cache.removeAll() }
            cache[key] = img
            return img
        } catch {
            log.warning("Thumbnail generation failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
    public func clearCache() {
        cache.removeAll()
    }
}
