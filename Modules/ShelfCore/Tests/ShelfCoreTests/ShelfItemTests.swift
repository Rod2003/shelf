import XCTest
@testable import ShelfCore

final class ShelfItemTests: XCTestCase {
    func testEquatabilityRequiresSamePayload() {
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_500)
        let a = ShelfItem(id: id, kind: .text("foo"), displayName: "n", createdAt: createdAt)
        let b = ShelfItem(id: id, kind: .text("foo"), displayName: "n", createdAt: createdAt)
        XCTAssertEqual(a, b)

        let differentText = ShelfItem(id: id, kind: .text("bar"), displayName: "n", createdAt: createdAt)
        XCTAssertNotEqual(a, differentText, "Different .text payload breaks equality")
    }

    func testKindEqualityIsTypeAware() {
        let id = UUID()
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
        XCTAssertNotEqual(
            textItem,
            urlItem,
            ".text(\"https://...\") must NOT equal .webURL with same string"
        )
    }
}
