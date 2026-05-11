// Integration tests for the persistence layer.
//
// Verifies the contract `DefaultsBackend` (Shelf app target) makes with
// `ShelfStore` (ShelfCore) when bound to a real `UserDefaults` suite:
//
//   1. A `Shelf` containing every `ShelfItemKind` variant survives a
//      fresh backend instantiation (process-restart-equivalent).
//   2. The `recentCap` (5) is enforced; the oldest shelf is evicted AND
//      its on-disk per-shelf key is removed (no orphaned blobs left
//      behind in the suite).
//   3. `ensureApplicationSupport()` is idempotent and safe to call on
//      every launch.
//
// Tests use isolated per-test `UserDefaults(suiteName:)` instances and
// distinct key prefixes so concurrent runs cannot collide. The suite is
// removed in `tearDown` to keep the host's defaults plist clean.

import Foundation
import XCTest

import ShelfCore

@testable import Shelf

final class PersistenceIntegrationTests: XCTestCase {

    /// Per-test UserDefaults suite name; unique per test method.
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// Per-test key prefix (matches `DefaultsBackend.canonicalKeyPrefix` shape).
    private var keyPrefix: String!
    /// Files / dirs created by tests that need cleaning up.
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

    // MARK: Helpers

    /// Build a real, on-disk file and return its URL plus a valid
    /// security-scoped `BookmarkRecord`. The file is added to
    /// `createdFiles` for `tearDown` cleanup.
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

    /// Backend bound to the per-test suite + prefix.
    private func makeBackend() -> DefaultsBackend {
        DefaultsBackend(defaults: defaults, keyPrefix: keyPrefix)
    }

    // MARK: Round-trip

    /// A `Shelf` containing every `ShelfItemKind` variant must survive
    /// a fresh `DefaultsBackend` + `ShelfStore` round-trip when bound
    /// to the same UserDefaults suite. Equivalent to "user quits Shelf,
    /// relaunches" — the persisted state must be byte-equal.
    func testFullRoundTripWith4ItemKinds() throws {
        let bookmarkRecord = try makeBookmarkRecord()
        let items: [ShelfItem] = [
            ShelfItem(kind: .fileBookmark(bookmarkRecord), displayName: "fileBookmark.txt"),
            ShelfItem(kind: .webURL(URL(string: "https://example.com")!), displayName: "example.com"),
            ShelfItem(kind: .text("hello roundtrip"), displayName: "hello roundtrip"),
            ShelfItem(kind: .clipboardImage(filename: "Image-roundtrip.png"), displayName: "Image-roundtrip.png"),
        ]
        let shelf = Shelf(name: "round-trip", items: items)

        // Write phase — backend instance #1.
        let backendA = makeBackend()
        let storeA = backendA.makeShelfStore()
        storeA.add(shelf)
        XCTAssertEqual(storeA.all().count, 1)
        XCTAssertEqual(storeA.get(shelfID: shelf.id), shelf)

        // Read phase — backend instance #2 (same suite + prefix; no shared
        // in-memory state). Forces ShelfStore to reload from disk.
        let backendB = makeBackend()
        let storeB = backendB.makeShelfStore()
        XCTAssertEqual(storeB.all().count, 1, "exactly one shelf must reload from disk")
        guard let restored = storeB.get(shelfID: shelf.id) else {
            return XCTFail("restored shelf missing from second backend")
        }
        XCTAssertEqual(restored, shelf, "Shelf must be Equatable-equal after roundtrip")
        XCTAssertEqual(restored.items.count, 4)

        // Spot-check each kind survived intact (Equatable equality above
        // already guarantees this; explicit asserts make the failure
        // message readable if the equality fails).
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

    // MARK: Cap eviction

    /// Adding more than `ShelfStore.recentCap` (5) shelves must evict
    /// the oldest one (tail of recency list = first-added). The on-disk
    /// per-shelf key must also be removed so no orphaned blobs leak
    /// across the cap boundary.
    func testCapEvictionDeletesOldestPerShelfKey() {
        let backend = makeBackend()
        let store = backend.makeShelfStore()

        // Add 6 shelves with strictly-increasing lastUsedAt so each is
        // distinguishable; the first inserted is the OLDEST and will
        // be the eviction target once we exceed the cap.
        let baseTime = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var shelves: [Shelf] = []
        for i in 0..<6 {
            let s = Shelf(
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

        // The on-disk per-shelf key for the evicted shelf must be removed
        // (shape: "<prefix>.shelf.<UUID-uppercase>").
        let evictedKey = "\(keyPrefix!).shelf.\(oldest.id.rawValue.uuidString)"
        XCTAssertNil(
            defaults.data(forKey: evictedKey),
            "evicted shelf's per-key blob must be deleted from defaults"
        )

        // Surviving shelves must still be on disk.
        for survivor in shelves.suffix(5) {
            let key = "\(keyPrefix!).shelf.\(survivor.id.rawValue.uuidString)"
            XCTAssertNotNil(
                defaults.data(forKey: key),
                "surviving shelf \(survivor.name) must still have its on-disk key"
            )
        }

        // The index key must contain exactly the 5 surviving IDs and not
        // the evicted one — guards against a regression where the index
        // is left out of sync with the per-shelf keys.
        let indexKey = "\(keyPrefix!).index"
        guard let indexData = defaults.data(forKey: indexKey) else {
            return XCTFail("index key must exist after add+evict cycle")
        }
        let restoredIDs = (try? JSONDecoder().decode([ShelfID].self, from: indexData)) ?? []
        XCTAssertEqual(restoredIDs.count, 5)
        XCTAssertFalse(
            restoredIDs.contains(where: { $0 == oldest.id }),
            "evicted shelf id must be absent from index"
        )
    }

    // MARK: ensureApplicationSupport idempotence

    /// `ensureApplicationSupport()` must be safe to call repeatedly — it
    /// is invoked on every launch by `AppDelegate`. The first call
    /// creates the directory; the second is a no-op that still returns
    /// the same URL without error.
    func testEnsureApplicationSupportIsIdempotent() {
        let backend = makeBackend()
        let first = backend.ensureApplicationSupport()
        XCTAssertNotNil(first, "first call must succeed in any normal env")
        let second = backend.ensureApplicationSupport()
        XCTAssertEqual(first, second, "second call must return same URL")

        // Verify the directory actually exists on disk.
        if let url = first {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            XCTAssertTrue(exists, "App Support tree must exist on disk")
            XCTAssertTrue(isDir.boolValue, "App Support tree must be a directory")
        }
    }

    // MARK: clearAll

    /// `clearAll()` removes every shelf-prefixed key from the suite so
    /// future backend instances start cold. Verifies the helper path
    /// used by tests + future shutdown hooks.
    func testClearAllRemovesAllShelfKeys() {
        let backend = makeBackend()
        let store = backend.makeShelfStore()
        store.add(Shelf(name: "to-be-cleared"))
        XCTAssertEqual(store.all().count, 1)

        backend.clearAll()

        // A fresh backend instance must see an empty store after clearAll.
        let backend2 = makeBackend()
        let store2 = backend2.makeShelfStore()
        XCTAssertEqual(store2.all().count, 0, "clearAll must wipe all on-disk shelves")

        // No keys with the prefix should remain in the suite.
        let leftovers = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("\(keyPrefix!).") }
        XCTAssertTrue(leftovers.isEmpty, "no prefixed keys should remain: \(leftovers)")
    }

    // MARK: keyPrefix isolation

    /// Two backends with different `keyPrefix` values must NOT see each
    /// other's shelves even when sharing the same UserDefaults suite —
    /// guards against a future regression where prefix is silently
    /// dropped or constants leak across suites.
    func testKeyPrefixIsolation() {
        let backendA = DefaultsBackend(defaults: defaults, keyPrefix: "iso.a.\(UUID().uuidString.prefix(8))")
        let backendB = DefaultsBackend(defaults: defaults, keyPrefix: "iso.b.\(UUID().uuidString.prefix(8))")

        let storeA = backendA.makeShelfStore()
        let storeB = backendB.makeShelfStore()

        storeA.add(Shelf(name: "only-A"))
        XCTAssertEqual(storeA.all().count, 1)
        XCTAssertEqual(storeB.all().count, 0, "backend B must not see backend A's shelves")
    }
}
