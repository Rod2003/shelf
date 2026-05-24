import Foundation
import XCTest

import ShelfCore

@testable import Shelf

final class PersistenceIntegrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var keyPrefix: String!
    private var createdFiles: [URL] = []

    override func setUp() {
        super.setUp()
        suiteName = "shelf.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "isolated UserDefaults suite must be available")
        keyPrefix = "shelf.test.\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        createdFiles.removeAll()
        defaults = nil
        suiteName = nil
        keyPrefix = nil
        super.tearDown()
    }
    private func makeBookmarkRecord() throws -> BookmarkRecord {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-persist-\(UUID().uuidString).txt")
        try Data("persist".utf8).write(to: url)
        createdFiles.append(url)
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return BookmarkRecord(bookmarkData: data, originalPath: url.path)
    }
    private func makeBackend() -> DefaultsBackend {
        DefaultsBackend(defaults: defaults, keyPrefix: keyPrefix)
    }
    func testFullRoundTripWith4ItemKinds() throws {
        let bookmarkRecord = try makeBookmarkRecord()
        let items: [ShelfItem] = [
            ShelfItem(kind: .fileBookmark(bookmarkRecord), displayName: "fileBookmark.txt"),
            ShelfItem(kind: .webURL(URL(string: "https://example.com")!), displayName: "example.com"),
            ShelfItem(kind: .text("hello roundtrip"), displayName: "hello roundtrip"),
            ShelfItem(kind: .clipboardImage(filename: "Image-roundtrip.png"), displayName: "Image-roundtrip.png"),
        ]
        let shelf = ShelfGroup(name: "round-trip", items: items)
        let backendA = makeBackend()
        let storeA = backendA.makeShelfStore()
        storeA.set(shelf)
        XCTAssertEqual(storeA.current(), shelf)
        let backendB = makeBackend()
        let storeB = backendB.makeShelfStore()
        guard let restored = storeB.current() else {
            return XCTFail("restored shelf missing from second backend")
        }
        XCTAssertEqual(restored, shelf, "ShelfGroup must be Equatable-equal after roundtrip")
        XCTAssertEqual(restored.items.count, 4)
        guard case let .fileBookmark(rec) = restored.items[0].kind else {
            return XCTFail("item[0] expected .fileBookmark, got \(restored.items[0].kind)")
        }
        XCTAssertEqual(rec.bookmarkData, bookmarkRecord.bookmarkData)

        guard case let .webURL(url) = restored.items[1].kind else {
            return XCTFail("item[1] expected .webURL, got \(restored.items[1].kind)")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com")

        guard case let .text(text) = restored.items[2].kind else {
            return XCTFail("item[2] expected .text, got \(restored.items[2].kind)")
        }
        XCTAssertEqual(text, "hello roundtrip")

        guard case let .clipboardImage(filename) = restored.items[3].kind else {
            return XCTFail("item[3] expected .clipboardImage, got \(restored.items[3].kind)")
        }
        XCTAssertEqual(filename, "Image-roundtrip.png")
    }

    func testShelfGroupDecodesPreRenameShelfJSONShape() throws {
        let id = ShelfGroupID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let lastUsedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let item = ShelfItem(
            id: ItemID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
            kind: .text("legacy payload"),
            displayName: "legacy payload",
            createdAt: createdAt
        )
        let preRenameJSON = try JSONEncoder().encode(
            LegacyShelfJSON(
                id: id,
                name: "legacy",
                items: [item],
                createdAt: createdAt,
                lastUsedAt: lastUsedAt
            )
        )

        let decoded = try JSONDecoder().decode(ShelfGroup.self, from: preRenameJSON)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "legacy")
        XCTAssertEqual(decoded.items, [item])
        XCTAssertEqual(decoded.createdAt, createdAt)
        XCTAssertEqual(decoded.lastUsedAt, lastUsedAt)
    }
    func testSettingShelfReplacesPreviousShelf() {
        let backend = makeBackend()
        let store = backend.makeShelfStore()
        let baseTime = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let first = ShelfGroup(
            name: "first",
            createdAt: baseTime,
            lastUsedAt: baseTime
        )
        let second = ShelfGroup(
            name: "second",
            createdAt: baseTime.addingTimeInterval(1),
            lastUsedAt: baseTime.addingTimeInterval(1)
        )

        store.set(first)
        store.set(second)

        XCTAssertEqual(store.current(), second)
        let restored = backend.makeShelfStore()
        XCTAssertEqual(restored.current(), second)
        XCTAssertNotNil(defaults.data(forKey: "\(keyPrefix!).shelf"))
        XCTAssertNil(defaults.data(forKey: "\(keyPrefix!).index"))
    }

    func testLegacyIndexedShelvesMigrateToSingleShelf() throws {
        let newer = ShelfGroup(name: "newer")
        let older = ShelfGroup(name: "older")
        defaults.set(
            try JSONEncoder().encode([newer.id, older.id]),
            forKey: "\(keyPrefix!).index"
        )
        defaults.set(
            try JSONEncoder().encode(newer),
            forKey: "\(keyPrefix!).shelf.\(newer.id.rawValue.uuidString)"
        )
        defaults.set(
            try JSONEncoder().encode(older),
            forKey: "\(keyPrefix!).shelf.\(older.id.rawValue.uuidString)"
        )

        let restored = makeBackend().makeShelfStore()

        XCTAssertEqual(restored.current(), newer)
        XCTAssertNotNil(defaults.data(forKey: "\(keyPrefix!).shelf"))
        XCTAssertNil(defaults.data(forKey: "\(keyPrefix!).index"))
        XCTAssertNil(defaults.data(forKey: "\(keyPrefix!).shelf.\(newer.id.rawValue.uuidString)"))
        XCTAssertNil(defaults.data(forKey: "\(keyPrefix!).shelf.\(older.id.rawValue.uuidString)"))
    }

    func testEnsureApplicationSupportIsIdempotent() {
        let backend = makeBackend()
        let first = backend.ensureApplicationSupport()
        XCTAssertNotNil(first, "first call must succeed in any normal env")
        let second = backend.ensureApplicationSupport()
        XCTAssertEqual(first, second, "second call must return same URL")
        if let url = first {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            XCTAssertTrue(exists, "App Support tree must exist on disk")
            XCTAssertTrue(isDir.boolValue, "App Support tree must be a directory")
        }
    }
    func testClearAllRemovesAllShelfKeys() {
        let backend = makeBackend()
        let store = backend.makeShelfStore()
        store.set(ShelfGroup(name: "to-be-cleared"))
        XCTAssertNotNil(store.current())

        backend.clearAll()
        let backend2 = makeBackend()
        let store2 = backend2.makeShelfStore()
        XCTAssertNil(store2.current(), "clearAll must wipe the on-disk shelf")
        let leftovers = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("\(keyPrefix!).") }
        XCTAssertTrue(leftovers.isEmpty, "no prefixed keys should remain: \(leftovers)")
    }
    func testKeyPrefixIsolation() {
        let backendA = DefaultsBackend(defaults: defaults, keyPrefix: "iso.a.\(UUID().uuidString.prefix(8))")
        let backendB = DefaultsBackend(defaults: defaults, keyPrefix: "iso.b.\(UUID().uuidString.prefix(8))")

        let storeA = backendA.makeShelfStore()
        let storeB = backendB.makeShelfStore()

        storeA.set(ShelfGroup(name: "only-A"))
        XCTAssertNotNil(storeA.current())
        XCTAssertNil(storeB.current(), "backend B must not see backend A's shelf")
    }
}

private struct LegacyShelfJSON: Codable {
    let id: ShelfGroupID
    let name: String
    let items: [ShelfItem]
    let createdAt: Date
    let lastUsedAt: Date
}
