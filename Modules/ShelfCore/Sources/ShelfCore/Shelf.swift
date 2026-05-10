// ShelfCore — pure Swift domain module for Shelf macOS app.
// No AppKit/SwiftUI imports allowed in this module.
import Foundation

/// A named collection of `ShelfItem`s. The shelf carries identity, label,
/// creation timestamp, and a "last used" timestamp used by ranking and UI
/// code in higher modules.
public struct Shelf: Codable, Equatable, Sendable {
    public let id: ShelfID
    public var name: String
    public var items: [ShelfItem]
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: ShelfID = ShelfID(),
        name: String = "",
        items: [ShelfItem] = [],
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
    }
}
