import XCTest
@testable import ShelfCore

final class BookmarkRecordTests: XCTestCase {

    func testInitWithEmptyDataAndPath() {
        let record = BookmarkRecord(bookmarkData: Data(), originalPath: "")
        XCTAssertEqual(record.bookmarkData, Data())
        XCTAssertEqual(record.originalPath, "")
        // createdAt is non-nil by virtue of Date type.
        XCTAssertLessThanOrEqual(record.createdAt.timeIntervalSinceNow, 1.0)
    }

    func testCodableRoundTripPreservesData() throws {
        // Generate ~1 KB of pseudo-random bytes.
        var bytes = [UInt8](repeating: 0, count: 1024)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        let payload = Data(bytes)
        let path = "/Users/test/Documents/example file.pdf"
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = BookmarkRecord(
            bookmarkData: payload,
            originalPath: path,
            createdAt: createdAt
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BookmarkRecord.self, from: encoded)
        XCTAssertEqual(decoded.bookmarkData, payload, "Bookmark Data must round-trip byte-equal")
        XCTAssertEqual(decoded.originalPath, path)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970,
                       createdAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(decoded, original)
    }

    func testEqualityRequiresAllFieldsMatch() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let baseData = Data([0x01, 0x02, 0x03])
        let basePath = "/tmp/a"

        let a = BookmarkRecord(bookmarkData: baseData, originalPath: basePath, createdAt: baseDate)
        let same = BookmarkRecord(bookmarkData: baseData, originalPath: basePath, createdAt: baseDate)
        XCTAssertEqual(a, same)

        let differentData = BookmarkRecord(bookmarkData: Data([0x99]), originalPath: basePath, createdAt: baseDate)
        XCTAssertNotEqual(a, differentData, "Different bookmarkData breaks equality")

        let differentPath = BookmarkRecord(bookmarkData: baseData, originalPath: "/tmp/b", createdAt: baseDate)
        XCTAssertNotEqual(a, differentPath, "Different originalPath breaks equality")

        let differentDate = BookmarkRecord(
            bookmarkData: baseData,
            originalPath: basePath,
            createdAt: baseDate.addingTimeInterval(1)
        )
        XCTAssertNotEqual(a, differentDate, "Different createdAt breaks equality")
    }

    func testCreatedAtDefaultsToNow() {
        let before = Date()
        let record = BookmarkRecord(bookmarkData: Data(), originalPath: "/")
        let after = Date()
        XCTAssertGreaterThanOrEqual(record.createdAt, before.addingTimeInterval(-0.001))
        XCTAssertLessThanOrEqual(record.createdAt, after.addingTimeInterval(0.001))
    }
}
