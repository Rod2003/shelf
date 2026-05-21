import Foundation

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

public enum ShelfItemKind: Codable, Equatable, Sendable {
    case fileBookmark(BookmarkRecord)
    case webURL(URL)
    case text(String)
    case clipboardImage(filename: String)
}
