import Foundation

public struct ShelfItem: Equatable, Sendable {
    public let id: UUID
    public var kind: ShelfItemKind
    public var displayName: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
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

extension ShelfItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLegacyUUID(forKey: .id)
        kind = try container.decode(ShelfItemKind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public enum ShelfItemKind: Codable, Equatable, Sendable {
    case fileBookmark(BookmarkRecord)
    case webURL(URL)
    case text(String)
    case clipboardImage(filename: String)
}
