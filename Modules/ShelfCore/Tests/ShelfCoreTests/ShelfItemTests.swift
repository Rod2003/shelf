import XCTest
@testable import ShelfCore

final class ShelfItemTests: XCTestCase {

    private func makeBookmark() -> BookmarkRecord {
        BookmarkRecord(
            bookmarkData: Data([0x01, 0x02, 0x03, 0x04]),
            originalPath: "/Users/test/file.txt",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testInitForFileBookmarkKind() {
        let bookmark = makeBookmark()
        let item = ShelfItem(kind: .fileBookmark(bookmark), displayName: "file.txt")
        XCTAssertEqual(item.displayName, "file.txt")
        if case let .fileBookmark(record) = item.kind {
            XCTAssertEqual(record, bookmark)
        } else {
            XCTFail("Expected .fileBookmark kind")
        }
    }

    func testInitForWebURLKind() {
        let url = URL(string: "https://example.com/path?q=1")!
        let item = ShelfItem(kind: .webURL(url), displayName: "Example")
        XCTAssertEqual(item.displayName, "Example")
        if case let .webURL(decodedURL) = item.kind {
            XCTAssertEqual(decodedURL, url)
        } else {
            XCTFail("Expected .webURL kind")
        }
    }

    func testInitForTextKind() {
        let item = ShelfItem(kind: .text("Hello, world!"), displayName: "Snippet")
        XCTAssertEqual(item.displayName, "Snippet")
        if case let .text(string) = item.kind {
            XCTAssertEqual(string, "Hello, world!")
        } else {
            XCTFail("Expected .text kind")
        }
    }

    func testInitForClipboardImageKind() {
        let item = ShelfItem(kind: .clipboardImage(filename: "screenshot.png"), displayName: "Screenshot")
        XCTAssertEqual(item.displayName, "Screenshot")
        if case let .clipboardImage(filename) = item.kind {
            XCTAssertEqual(filename, "screenshot.png")
        } else {
            XCTFail("Expected .clipboardImage kind")
        }
    }

    func testCodableRoundTripForFileBookmarkKind() throws {
        let bookmark = makeBookmark()
        let original = ShelfItem(
            id: ItemID(rawValue: UUID()),
            kind: .fileBookmark(bookmark),
            displayName: "file.txt",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShelfItem.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripForWebURLKind() throws {
        let url = URL(string: "https://example.com/")!
        let original = ShelfItem(
            id: ItemID(rawValue: UUID()),
            kind: .webURL(url),
            displayName: "Example",
            createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShelfItem.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripForTextKind() throws {
        let original = ShelfItem(
            id: ItemID(rawValue: UUID()),
            kind: .text("Some snippet with unicode: café"),
            displayName: "Note",
            createdAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShelfItem.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripForClipboardImageKind() throws {
        let original = ShelfItem(
            id: ItemID(rawValue: UUID()),
            kind: .clipboardImage(filename: "shot 2026-05-03.png"),
            displayName: "Clipboard image",
            createdAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShelfItem.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEquatabilityRequiresSamePayload() {
        let id = ItemID(rawValue: UUID())
        let createdAt = Date(timeIntervalSince1970: 1_700_000_500)
        let a = ShelfItem(id: id, kind: .text("foo"), displayName: "n", createdAt: createdAt)
        let b = ShelfItem(id: id, kind: .text("foo"), displayName: "n", createdAt: createdAt)
        XCTAssertEqual(a, b)

        let differentText = ShelfItem(id: id, kind: .text("bar"), displayName: "n", createdAt: createdAt)
        XCTAssertNotEqual(a, differentText, "Different .text payload breaks equality")
    }

    func testKindEqualityIsTypeAware() {
        let id = ItemID(rawValue: UUID())
        let createdAt = Date(timeIntervalSince1970: 1_700_000_600)
        let textItem = ShelfItem(
            id: id,
            kind: .text("https://example.com"),
            displayName: "n",
            createdAt: createdAt
        )
        let urlItem = ShelfItem(
            id: id,
            kind: .webURL(URL(string: "https://example.com")!),
            displayName: "n",
            createdAt: createdAt
        )
        XCTAssertNotEqual(textItem, urlItem,
                          ".text(\"https://...\") must NOT equal .webURL with same string")
    }
}
