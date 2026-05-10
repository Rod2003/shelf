// ShelfCore — pure Swift domain module for Shelf macOS app.
// No AppKit/SwiftUI imports allowed in this module.
import Foundation

/// Opaque holder for a security-scoped bookmark blob produced via
/// `URL.bookmarkData(...)` against a file URL the user dropped onto a Shelf.
///
/// `originalPath` is retained for diagnostics and debug logging only; the
/// authoritative way to recover the URL is to resolve `bookmarkData` through
/// `BookmarkResolver` (T17). Do NOT treat `originalPath` as a substitute for
/// resolving the bookmark.
public struct BookmarkRecord: Codable, Equatable, Sendable {
    public let bookmarkData: Data
    public let originalPath: String
    public let createdAt: Date

    public init(
        bookmarkData: Data,
        originalPath: String,
        createdAt: Date = Date()
    ) {
        self.bookmarkData = bookmarkData
        self.originalPath = originalPath
        self.createdAt = createdAt
    }
}
