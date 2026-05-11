// Resolves opaque `BookmarkRecord.bookmarkData` blobs back into concrete
// file URLs at drag-OUT time, handling stale-bookmark refresh and the
// security-scoped accessor pairing required by a future sandbox migration.

import Foundation
import OSLog
import ShelfCore

/// Resolves opaque bookmark blobs to file URLs, handling stale bookmark refresh.
///
/// While the app is unsandboxed `startAccessingSecurityScopedResource()` is a
/// no-op; the API is preserved so the eventual sandbox flip needs no caller
/// changes.
///
/// Sendable: the resolver holds only a `Logger` (Sendable) and has no mutable
/// state — it is effectively immutable. Declared `Sendable` explicitly so
/// it can be captured into the `@Sendable` operation queue closure used by
/// `FilePromiseDelegate.writePromiseTo`.
public final class BookmarkResolver: Sendable {

    private let log = Logger(subsystem: "dev.rod.shelf", category: "persist")

    public init() {}

    /// Result of a successful bookmark resolution.
    ///
    /// - `url`: The resolved file URL. The resolver has already begun a
    ///   security-scoped access on this URL; callers MUST invoke
    ///   `BookmarkResolver.release(_:)` (or `url.stopAccessingSecurityScopedResource()`)
    ///   when finished.
    /// - `isStale`: `true` if the bookmark was stale; the caller should
    ///   replace the persisted `BookmarkRecord.bookmarkData` with
    ///   `refreshedData` to avoid repeated refresh churn on subsequent
    ///   resolves.
    /// - `refreshedData`: When `isStale == true`, fresh bookmark Data
    ///   computed from the resolved URL; otherwise the original input data
    ///   is returned unchanged so callers may store it unconditionally.
    public struct Resolution {
        public let url: URL
        public let isStale: Bool
        public let refreshedData: Data

        public init(url: URL, isStale: Bool, refreshedData: Data) {
            self.url = url
            self.isStale = isStale
            self.refreshedData = refreshedData
        }
    }

    /// Errors thrown by `resolve(_:)`.
    ///
    /// - `bookmarkResolutionFailed`: `URL(resolvingBookmarkData:...)` threw.
    ///   The underlying error is forwarded for logging / diagnostics.
    /// - `fileNoLongerExists`: The bookmark resolved to a path the file
    ///   system no longer recognizes (file deleted or moved out of resolver
    ///   reach). The original recorded path is included for diagnostics —
    ///   it is NOT a substitute for retrying the resolve, but it is useful
    ///   in user-facing error toasts.
    public enum ResolutionError: Error {
        case bookmarkResolutionFailed(underlying: Error)
        case fileNoLongerExists(originalPath: String)
    }

    /// Resolve a `BookmarkRecord` to a concrete file URL.
    ///
    /// On success, the resolver begins a security-scoped access on the
    /// returned URL. Callers MUST invoke `release(_:)` when finished
    /// (typically inside `defer { resolver.release(resolution.url) }`).
    ///
    /// Throws `ResolutionError.bookmarkResolutionFailed` if the bookmark
    /// could not be resolved at all, or `ResolutionError.fileNoLongerExists`
    /// if the bookmark resolved but the underlying file is gone.
    public func resolve(_ record: BookmarkRecord) throws -> Resolution {
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: record.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            log.error("Bookmark resolution failed for original=\(record.originalPath, privacy: .public): \(String(describing: error), privacy: .public)")
            throw ResolutionError.bookmarkResolutionFailed(underlying: error)
        }

        // Begin security-scoped access. No-op outside the sandbox; harmless to
        // call. Paired with `release(_:)` (or direct
        // `stopAccessingSecurityScopedResource()`) by the caller.
        _ = url.startAccessingSecurityScopedResource()

        var refreshed = record.bookmarkData
        if stale {
            log.warning("Bookmark stale for \(record.originalPath, privacy: .public); attempting refresh")
            do {
                refreshed = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                log.error("Failed to refresh stale bookmark for \(record.originalPath, privacy: .public): \(String(describing: error), privacy: .public)")
                // Return the original data; the caller may discard it if the
                // file is also missing (handled below).
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            log.warning("Bookmark resolved to non-existent path \(url.path, privacy: .public)")
            throw ResolutionError.fileNoLongerExists(originalPath: record.originalPath)
        }

        return Resolution(url: url, isStale: stale, refreshedData: refreshed)
    }

    /// Pair to the implicit `startAccessingSecurityScopedResource()` invoked
    /// during `resolve(_:)`. No-op outside the sandbox; mandatory for sandbox
    /// correctness once the app is signed and entitled.
    public func release(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
