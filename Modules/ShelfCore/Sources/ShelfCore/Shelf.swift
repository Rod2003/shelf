import Foundation

public struct ShelfGroup: Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var items: [ShelfItem]
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: UUID = UUID(),
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

extension ShelfGroup: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case items
        case createdAt
        case lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLegacyUUID(forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        items = try container.decode([ShelfItem].self, forKey: .items)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(items, forKey: .items)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
    }
}
