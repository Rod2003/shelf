import Foundation

enum LegacyUUIDCodingKey: String, CodingKey {
    case rawValue
}

extension KeyedDecodingContainer {
    func decodeLegacyUUID(forKey key: Key) throws -> UUID {
        if let uuid = try? decode(UUID.self, forKey: key) {
            return uuid
        }
        let nested = try nestedContainer(keyedBy: LegacyUUIDCodingKey.self, forKey: key)
        return try nested.decode(UUID.self, forKey: .rawValue)
    }
}

struct WrappedOrBareUUID: Decodable {
    let value: UUID

    init(from decoder: Decoder) throws {
        if let uuid = try? UUID(from: decoder) {
            value = uuid
            return
        }
        let container = try decoder.container(keyedBy: LegacyUUIDCodingKey.self)
        value = try container.decode(UUID.self, forKey: .rawValue)
    }
}
