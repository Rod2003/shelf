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

    /// `bookmarkData` and `createdAt` must round-trip byte-equal; the
    /// diagnostic `originalPath` field is deliberately redacted on encode
    /// for privacy (see BookmarkRecord docstring).
    func testCodableRoundTripPreservesLoadBearingFields() throws {
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
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970,
                       createdAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(decoded.originalPath, "",
                       "originalPath must NOT survive a Codable round-trip — see privacy note")
        XCTAssertEqual(decoded, original,
                       "Equatable ignores originalPath, so the records must compare equal")
    }

    /// The encoded payload must not contain `originalPath` as a key OR the
    /// path's directory components as a value. This is the privacy guarantee
    /// the docstring promises.
    func testEncodedPayloadDoesNotLeakPath() throws {
        let secretPath = "/Users/foo/Documents/SECRET-MARKER-1234/scan.pdf"
        let record = BookmarkRecord(
            bookmarkData: Data([0x01, 0x02, 0x03]),
            originalPath: secretPath
        )
        let encoded = try JSONEncoder().encode(record)
        guard let jsonString = String(data: encoded, encoding: .utf8) else {
            return XCTFail("Encoded record was not valid UTF-8")
        }
        XCTAssertFalse(jsonString.contains("originalPath"),
                       "Encoded JSON must not contain the originalPath key")
        XCTAssertFalse(jsonString.contains("SECRET-MARKER-1234"),
                       "Encoded JSON must not contain user directory components")
    }

    func testEqualityIgnoresOriginalPath() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let baseData = Data([0x01, 0x02, 0x03])

        let a = BookmarkRecord(bookmarkData: baseData, originalPath: "/tmp/a", createdAt: baseDate)
        let same = BookmarkRecord(bookmarkData: baseData, originalPath: "/tmp/a", createdAt: baseDate)
        XCTAssertEqual(a, same)

        let differentData = BookmarkRecord(bookmarkData: Data([0x99]), originalPath: "/tmp/a", createdAt: baseDate)
        XCTAssertNotEqual(a, differentData, "Different bookmarkData breaks equality")

        let differentPath = BookmarkRecord(bookmarkData: baseData, originalPath: "/tmp/b", createdAt: baseDate)
        XCTAssertEqual(a, differentPath,
                       "originalPath is a diagnostic-only field and MUST NOT affect equality")

        let differentDate = BookmarkRecord(
            bookmarkData: baseData,
            originalPath: "/tmp/a",
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
