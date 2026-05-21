import Foundation

/// Do not persist or compare `originalPath`; resolve `bookmarkData` for recoverable URLs.
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
