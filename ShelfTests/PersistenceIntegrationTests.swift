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
        storeA.add(shelf)
        XCTAssertEqual(storeA.all().count, 1)
        XCTAssertEqual(storeA.get(shelfID: shelf.id), shelf)
        let backendB = makeBackend()
        let storeB = backendB.makeShelfStore()
        XCTAssertEqual(storeB.all().count, 1, "exactly one shelf must reload from disk")
        guard let restored = storeB.get(shelfID: shelf.id) else {
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
    func testCapEvictionDeletesOldestPerShelfKey() {
        let backend = makeBackend()
        let store = backend.makeShelfStore()
        let baseTime = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var shelves: [ShelfGroup] = []
        for i in 0..<6 {
            let s = ShelfGroup(
                name: "shelf-\(i)",
                createdAt: baseTime.addingTimeInterval(TimeInterval(i)),
                lastUsedAt: baseTime.addingTimeInterval(TimeInterval(i))
            )
            shelves.append(s)
            store.add(s)
        }

        XCTAssertEqual(ShelfStore.recentCap, 5, "spec sanity check; cap is 5")
        XCTAssertEqual(store.all().count, 5, "must enforce cap of 5")

        let oldest = shelves[0]
        XCTAssertNil(
            store.get(shelfID: oldest.id),
            "first-added shelf must be evicted from in-memory state"
        )
        let evictedKey = "\(keyPrefix!).shelf.\(oldest.id.rawValue.uuidString)"
        XCTAssertNil(
            defaults.data(forKey: evictedKey),
            "evicted shelf's per-key blob must be deleted from defaults"
        )
        for survivor in shelves.suffix(5) {
            let key = "\(keyPrefix!).shelf.\(survivor.id.rawValue.uuidString)"
            XCTAssertNotNil(
                defaults.data(forKey: key),
                "surviving shelf \(survivor.name) must still have its on-disk key"
            )
        }
        let indexKey = "\(keyPrefix!).index"
        guard let indexData = defaults.data(forKey: indexKey) else {
            return XCTFail("index key must exist after add+evict cycle")
        }
        let restoredIDs = (try? JSONDecoder().decode([ShelfGroupID].self, from: indexData)) ?? []
        XCTAssertEqual(restoredIDs.count, 5)
        XCTAssertFalse(
            restoredIDs.contains(where: { $0 == oldest.id }),
            "evicted shelf id must be absent from index"
        )
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
        store.add(ShelfGroup(name: "to-be-cleared"))
        XCTAssertEqual(store.all().count, 1)

        backend.clearAll()
        let backend2 = makeBackend()
        let store2 = backend2.makeShelfStore()
        XCTAssertEqual(store2.all().count, 0, "clearAll must wipe all on-disk shelves")
        let leftovers = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("\(keyPrefix!).") }
        XCTAssertTrue(leftovers.isEmpty, "no prefixed keys should remain: \(leftovers)")
    }
    func testKeyPrefixIsolation() {
        let backendA = DefaultsBackend(defaults: defaults, keyPrefix: "iso.a.\(UUID().uuidString.prefix(8))")
        let backendB = DefaultsBackend(defaults: defaults, keyPrefix: "iso.b.\(UUID().uuidString.prefix(8))")

        let storeA = backendA.makeShelfStore()
        let storeB = backendB.makeShelfStore()

        storeA.add(ShelfGroup(name: "only-A"))
        XCTAssertEqual(storeA.all().count, 1)
        XCTAssertEqual(storeB.all().count, 0, "backend B must not see backend A's shelves")
    }
}

private struct LegacyShelfJSON: Codable {
    let id: ShelfGroupID
    let name: String
    let items: [ShelfItem]
    let createdAt: Date
    let lastUsedAt: Date
}
