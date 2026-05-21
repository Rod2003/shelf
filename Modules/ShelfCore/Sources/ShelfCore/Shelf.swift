import Foundation

public struct ShelfGroup: Codable, Equatable, Sendable {
    public let id: ShelfGroupID
    public var name: String
    public var items: [ShelfItem]
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: ShelfGroupID = ShelfGroupID(),
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
