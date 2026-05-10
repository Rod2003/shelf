import XCTest
@testable import ShelfCore

final class IdentifiersTests: XCTestCase {

    // MARK: - ShelfID

    func testShelfIDInitWithDefaultUUIDIsUnique() {
        let a = ShelfID()
        let b = ShelfID()
        XCTAssertNotEqual(a, b, "Two default-init ShelfIDs should have distinct UUIDs")
        XCTAssertNotEqual(a.rawValue, b.rawValue)
    }

    func testShelfIDInitWithExplicitUUIDPreservesValue() {
        let uuid = UUID()
        let id = ShelfID(rawValue: uuid)
        XCTAssertEqual(id.rawValue, uuid)
    }

    func testShelfIDCodableRoundTrip() throws {
        let original = ShelfID(rawValue: UUID())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShelfID.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.rawValue, original.rawValue)
    }

    func testShelfIDHashableAllowsSetInsertion() {
        let uuid = UUID()
        let a = ShelfID(rawValue: uuid)
        let b = ShelfID(rawValue: uuid)
        let c = ShelfID()
        var set: Set<ShelfID> = []
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1, "Equal IDs collapse to one entry in Set")
        set.insert(c)
        XCTAssertEqual(set.count, 2, "Distinct ID adds a second entry")
    }

    // MARK: - ItemID

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

    // MARK: - Type Distinction (compile-time)

    func testShelfIDAndItemIDAreDistinctTypes() {
        // This test verifies at compile time that ShelfID and ItemID are
        // distinct types and cannot be silently interchanged. The body
        // simply confirms each type has its own metatype identity.
        let shelfMeta: Any.Type = ShelfID.self
        let itemMeta: Any.Type = ItemID.self
        XCTAssertFalse(shelfMeta == itemMeta, "ShelfID and ItemID must be distinct types")
        // Verify each type has its own metatype.
        XCTAssertTrue(ShelfID.self == ShelfID.self)
        XCTAssertTrue(ItemID.self == ItemID.self)
    }
}
