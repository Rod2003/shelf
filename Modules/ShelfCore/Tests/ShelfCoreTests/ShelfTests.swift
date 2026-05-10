import XCTest
@testable import ShelfCore

final class ShelfTests: XCTestCase {

    func testInitWithDefaultsCreatesEmptyShelf() {
        let shelf = Shelf()
        XCTAssertEqual(shelf.name, "")
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertEqual(shelf.lastUsedAt, shelf.createdAt,
                       "lastUsedAt should default to createdAt")
    }

    func testInitWithItemsRetainsItems() {
        let item = ShelfItem(kind: .text("hello"), displayName: "Greeting")
        let shelf = Shelf(name: "Inbox", items: [item])
        XCTAssertEqual(shelf.name, "Inbox")
        XCTAssertEqual(shelf.items.count, 1)
        XCTAssertEqual(shelf.items.first, item)
    }

    func testCodableRoundTripWithMixedItems() throws {
        let bookmark = BookmarkRecord(
            bookmarkData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            originalPath: "/Users/test/doc.pdf",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let items: [ShelfItem] = [
            ShelfItem(
                id: ItemID(rawValue: UUID()),
                kind: .fileBookmark(bookmark),
                displayName: "doc.pdf",
                createdAt: Date(timeIntervalSince1970: 1_700_000_010)
            ),
            ShelfItem(
                id: ItemID(rawValue: UUID()),
                kind: .webURL(URL(string: "https://example.com")!),
                displayName: "Example",
                createdAt: Date(timeIntervalSince1970: 1_700_000_020)
            ),
            ShelfItem(
                id: ItemID(rawValue: UUID()),
                kind: .text("a snippet"),
                displayName: "Snippet",
                createdAt: Date(timeIntervalSince1970: 1_700_000_030)
            ),
            ShelfItem(
                id: ItemID(rawValue: UUID()),
                kind: .clipboardImage(filename: "img.png"),
                displayName: "Image",
                createdAt: Date(timeIntervalSince1970: 1_700_000_040)
            )
        ]
        let createdAt = Date(timeIntervalSince1970: 1_699_000_000)
        let lastUsedAt = Date(timeIntervalSince1970: 1_700_500_000)
        let original = Shelf(
            id: ShelfID(rawValue: UUID()),
            name: "Mixed",
            items: items,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Shelf.self, from: data)
        XCTAssertEqual(decoded, original,
                       "Full Shelf with one item per kind must round-trip equal")
        XCTAssertEqual(decoded.items.count, 4)
    }

    func testLastUsedAtDefaultsToCreatedAt() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let shelf = Shelf(createdAt: createdAt)
        XCTAssertEqual(shelf.lastUsedAt, createdAt)
        XCTAssertEqual(shelf.createdAt, createdAt)
    }

    func testLastUsedAtCanBeMutated() {
        var shelf = Shelf(name: "Mutable")
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        shelf.lastUsedAt = newDate
        XCTAssertEqual(shelf.lastUsedAt, newDate)
        // createdAt is `let` and stays at its original value.
        XCTAssertNotEqual(shelf.createdAt, newDate)
    }
}
