// ShelfCore — pure Swift domain module for Shelf macOS app.
// No AppKit/SwiftUI imports allowed in this module.
import Foundation

/// One entry on a `Shelf`. Items are typed by their `ShelfItemKind` payload
/// and identified by an `ItemID`.
public struct ShelfItem: Codable, Equatable, Sendable {
    public let id: ItemID
    public var kind: ShelfItemKind
    public var displayName: String
    public let createdAt: Date

    public init(
        id: ItemID = ItemID(),
        kind: ShelfItemKind,
        displayName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

/// The payload variants a `ShelfItem` can carry.
///
/// - `fileBookmark`: Security-scoped bookmark blob plus diagnostics path.
///   The authoritative URL must be obtained by resolving `BookmarkRecord.bookmarkData`.
/// - `webURL`: A bare web URL captured from a drag from a browser.
/// - `text`: A plain-text snippet copied or dropped onto the shelf.
/// - `clipboardImage`: A clipboard-sourced image, persisted out-of-band by
///   filename only (the bytes live elsewhere; ShelfCore does not own them).
public enum ShelfItemKind: Codable, Equatable, Sendable {
    case fileBookmark(BookmarkRecord)
    case webURL(URL)
    case text(String)
    case clipboardImage(filename: String)
}
