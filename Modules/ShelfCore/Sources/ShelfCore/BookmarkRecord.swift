// ShelfCore — pure Swift domain module for Shelf macOS app.
// No AppKit/SwiftUI imports allowed in this module.
import Foundation

/// Opaque holder for a security-scoped bookmark blob produced via
/// `URL.bookmarkData(...)` against a file URL the user dropped onto a Shelf.
///
/// `originalPath` is retained for diagnostics and debug logging only; the
/// authoritative way to recover the URL is to resolve `bookmarkData` through
/// `BookmarkResolver`. Do not treat `originalPath` as a substitute for
/// resolving the bookmark.
///
/// ## Privacy
/// `originalPath` is **deliberately excluded** from `Codable` and `Equatable`.
/// The UserDefaults plist this record is persisted into lives at
/// `~/Library/Preferences/dev.rod.shelf.plist`, which is readable by any
/// process running as the user. Persisting full filesystem paths there would
/// leak directory structure (e.g. `/Users/foo/Documents/medical/...`) that
/// the bookmark blob itself does not expose in cleartext. After a decode
/// round-trip `originalPath` is the empty string; callers that need a
/// filesystem path must resolve the bookmark.
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

    private enum CodingKeys: String, CodingKey {
        case bookmarkData
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bookmarkData = try c.decode(Data.self, forKey: .bookmarkData)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.originalPath = ""
    }

    public static func == (lhs: BookmarkRecord, rhs: BookmarkRecord) -> Bool {
        lhs.bookmarkData == rhs.bookmarkData && lhs.createdAt == rhs.createdAt
    }
}
