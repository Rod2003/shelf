// Shelf — async thumbnail generator with in-memory cache (T19).
//
// Wraps `QLThumbnailGenerator` behind an `actor` so that concurrent callers
// from multiple SwiftUI cells share a single cache without manual locking.
// The cache is keyed by file path + requested size + scale; entries are
// `NSImage` references suitable for direct rendering by `Image(nsImage:)`.
//
// V1 cache policy is intentionally minimal: a coarse capacity guard wipes
// the entire dictionary at `maxCacheCount`. This avoids LRU bookkeeping
// (and the synchronization cost it implies) while still bounding memory
// for shelves that hold hundreds of items. A future task may swap in
// `NSCache` if eviction granularity becomes a concern.
//
// Errors from `QLThumbnailGenerator` are logged and converted to `nil` —
// callers fall back to the SF Symbol placeholder rendered by
// `ShelfItemView`. We never throw; UI cells should not have to model
// thumbnail-generation failure as an error path.
import AppKit
import QuickLookThumbnailing
import OSLog

/// Actor-isolated thumbnail generator with in-memory cache.
///
/// Thread-safe by construction: all cache reads/writes happen on the
/// actor's executor, so concurrent SwiftUI `.task` invocations cannot
/// race on the underlying dictionary.
public actor ThumbnailService {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")
    private var cache: [String: NSImage] = [:]
    private let maxCacheCount: Int

    public init(maxCacheCount: Int = 200) {
        self.maxCacheCount = maxCacheCount
    }

    /// Return a cached or freshly generated thumbnail for `url`.
    ///
    /// - Parameters:
    ///   - url: The file URL to render.
    ///   - size: Logical (point) size for the requested representation.
    ///     Defaults to 96×96 to match the v1 grid cell.
    ///   - scale: Backing-store scale factor; pass `2` for Retina.
    /// - Returns: An `NSImage` on success, `nil` if QL could not produce
    ///   a representation. The error is logged but not surfaced.
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
            // Coarse capacity guard. See file header for rationale.
            if cache.count >= maxCacheCount { cache.removeAll() }
            cache[key] = img
            return img
        } catch {
            log.warning("Thumbnail generation failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Drop all cached thumbnails. Useful when the app is told to reduce
    /// memory pressure; not currently wired into a system signal.
    public func clearCache() {
        cache.removeAll()
    }
}
