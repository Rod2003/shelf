import XCTest
@testable import ShelfCore

final class IdentifiersTests: XCTestCase {

    func testShelfIDInitWithDefaultUUIDIsUnique() {
        let a = ShelfGroupID()
        let b = ShelfGroupID()
        XCTAssertNotEqual(a, b, "Two default-init ShelfIDs should have distinct UUIDs")
        XCTAssertNotEqual(a.rawValue, b.rawValue)
    }

    func testShelfIDInitWithExplicitUUIDPreservesValue() {
        let uuid = UUID()
        let id = ShelfGroupID(rawValue: uuid)
        XCTAssertEqual(id.rawValue, uuid)
    }

    func testShelfIDCodableRoundTrip() throws {
        let original = ShelfGroupID(rawValue: UUID())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShelfGroupID.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.rawValue, original.rawValue)
    }

    func testShelfIDHashableAllowsSetInsertion() {
        let uuid = UUID()
        let a = ShelfGroupID(rawValue: uuid)
        let b = ShelfGroupID(rawValue: uuid)
        let c = ShelfGroupID()
        var set: Set<ShelfGroupID> = []
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1, "Equal IDs collapse to one entry in Set")
        set.insert(c)
        XCTAssertEqual(set.count, 2, "Distinct ID adds a second entry")
    }

    func testItemIDInitWithDefaultUUIDIsUnique() {
        let a = ItemID()
        let b = ItemID()
        XCTAssertNotEqual(a, b, "Two default-init ItemIDs should have distinct UUIDs")
        XCTAssertNotEqual(a.rawValue, b.rawValue)
    }

    func testItemIDInitWithExplicitUUIDPreservesValue() {
        let uuid = UUID()
        let id = ItemID(rawValue: uuid)
        XCTAssertEqual(id.rawValue, uuid)
    }

    func testItemIDCodableRoundTrip() throws {
        let original = ItemID(rawValue: UUID())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ItemID.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.rawValue, original.rawValue)
    }

    func testItemIDHashableAllowsSetInsertion() {
        let uuid = UUID()
        let a = ItemID(rawValue: uuid)
        let b = ItemID(rawValue: uuid)
        let c = ItemID()
        var set: Set<ItemID> = []
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1)
        set.insert(c)
        XCTAssertEqual(set.count, 2)
    }

    func testShelfIDAndItemIDAreDistinctTypes() {
        let shelfMeta: Any.Type = ShelfGroupID.self
        let itemMeta: Any.Type = ItemID.self
        XCTAssertFalse(shelfMeta == itemMeta, "ShelfGroupID and ItemID must be distinct types")
        XCTAssertTrue(ShelfGroupID.self == ShelfGroupID.self)
        XCTAssertTrue(ItemID.self == ItemID.self)
    }
}
