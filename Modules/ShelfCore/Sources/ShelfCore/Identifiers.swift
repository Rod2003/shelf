// ShelfCore — pure Swift domain module for Shelf macOS app.
// No AppKit/SwiftUI imports allowed in this module.
import Foundation

/// Strongly-typed identifier for a `Shelf`. Wraps a `UUID` to prevent
/// accidental mixing with `ItemID` or other UUID-based identifiers.
public struct ShelfID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Strongly-typed identifier for a `ShelfItem`. Distinct from `ShelfID`
/// at the type level so the compiler rejects mixed usage.
public struct ItemID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
