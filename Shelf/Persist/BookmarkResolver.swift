import Foundation
import OSLog
import ShelfCore

final class BookmarkResolver: Sendable {

    private let log = Logger(subsystem: "dev.rod.shelf", category: "persist")

    init() {}

    struct Resolution {
        let url: URL
        let isStale: Bool
        let refreshedData: Data
    }

    enum ResolutionError: Error {
        case bookmarkResolutionFailed(underlying: Error)
        case fileNoLongerExists(originalPath: String)
    }

    func resolve(_ record: BookmarkRecord) throws -> Resolution {
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

        // Call `release(_:)` after using the resolved URL.
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
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            log.warning("Bookmark resolved to non-existent path \(url.path, privacy: .public)")
            throw ResolutionError.fileNoLongerExists(originalPath: record.originalPath)
        }

        return Resolution(url: url, isStale: stale, refreshedData: refreshed)
    }

    func release(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
