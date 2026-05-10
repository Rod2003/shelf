import XCTest
@testable import ShelfCore

final class ShelfStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Returns a unique UserDefaults suite for test isolation. Each test
    /// gets its own suite so concurrent tests cannot collide and so leaking
    /// state from a previous run cannot influence assertions.
    private func makeIsolatedDefaults(file: StaticString = #file, line: UInt = #line)
        -> (defaults: UserDefaults, suiteName: String)
    {
        let suiteName = "test.shelfstore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("UserDefaults(suiteName:) returned nil", file: file, line: line)
            // Return a sentinel that is unique to this call so callers don't
            // crash even if the assert above turned into a soft failure.
            return (UserDefaults.standard, suiteName)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    /// Tear down a suite created by `makeIsolatedDefaults`.
    private func cleanupDefaults(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeShelf(
        name: String,
        items: [ShelfItem] = [],
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) -> Shelf {
        Shelf(
            id: ShelfID(rawValue: UUID()),
            name: name,
            items: items,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt ?? createdAt
        )
    }

    private func makeBookmarkItem() -> ShelfItem {
        ShelfItem(
            id: ItemID(rawValue: UUID()),
            kind: .fileBookmark(BookmarkRecord(
                bookmarkData: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02]),
                originalPath: "/Users/test/file.pdf",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )),
            displayName: "file.pdf",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    private func makeWebURLItem() -> ShelfItem {
        ShelfItem(
            id: ItemID(rawValue: UUID()),
            kind: .webURL(URL(string: "https://example.com/path?q=1")!),
            displayName: "Example",
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
    }

    private func makeTextItem() -> ShelfItem {
        ShelfItem(
            id: ItemID(rawValue: UUID()),
            kind: .text("snippet"),
            displayName: "Snippet",
            createdAt: Date(timeIntervalSince1970: 1_700_000_020)
        )
    }

    private func makeClipboardImageItem() -> ShelfItem {
        ShelfItem(
            id: ItemID(rawValue: UUID()),
            kind: .clipboardImage(filename: "img.png"),
            displayName: "Clipboard image",
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        )
    }

    // MARK: - 1. Add single shelf

    func testAddSingleShelf() {
        let store = ShelfStore(backend: .inMemory)
        XCTAssertEqual(store.all().count, 0, "Fresh store starts empty")

        let shelf = makeShelf(name: "First", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.add(shelf)

        let all = store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first, shelf)
    }

    // MARK: - 2. Cap enforcement

    func testAddPastCapEvictsOldest() {
        let store = ShelfStore(backend: .inMemory)

        // Add 6 shelves with strictly increasing timestamps. Oldest = first
        // added (and lives at the tail of the recency list); newest = last.
        var added: [Shelf] = []
        for i in 0 ..< 6 {
            let s = makeShelf(
                name: "shelf-\(i)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
            )
            added.append(s)
            store.add(s)
        }

        let all = store.all()
        XCTAssertEqual(all.count, ShelfStore.recentCap, "Cap is hardcoded to 5")
        XCTAssertEqual(all.count, 5)

        // The very first shelf (i=0) should be evicted; the remaining 5 are
        // i=5 (front, most recent) ... i=1 (tail).
        XCTAssertFalse(all.contains(where: { $0.id == added[0].id }),
                       "Oldest shelf must be evicted")
        XCTAssertEqual(all[0], added[5], "Most recent at front")
        XCTAssertEqual(all[4], added[1], "Oldest surviving at tail")
    }

    // MARK: - 3. Eviction deletes UserDefaults key

    func testEvictionDeletesUserDefaultsKey() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))

        var added: [Shelf] = []
        for i in 0 ..< 6 {
            let s = makeShelf(
                name: "shelf-\(i)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
            )
            added.append(s)
            store.add(s)
        }

        let firstID = added[0].id
        let firstKey = "\(prefix).shelf.\(firstID.rawValue.uuidString)"
        XCTAssertNil(env.defaults.data(forKey: firstKey),
                     "Evicted shelf's UserDefaults key must be removed")

        // Sanity: a surviving shelf's key still exists.
        let lastID = added[5].id
        let lastKey = "\(prefix).shelf.\(lastID.rawValue.uuidString)"
        XCTAssertNotNil(env.defaults.data(forKey: lastKey),
                        "Newest shelf's key must still be present")
    }

    // MARK: - 4. Remove existing

    func testRemoveExisting() {
        let store = ShelfStore(backend: .inMemory)

        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        let s2 = makeShelf(name: "b", createdAt: Date(timeIntervalSince1970: 1_700_000_002))
        let s3 = makeShelf(name: "c", createdAt: Date(timeIntervalSince1970: 1_700_000_003))
        store.add(s1)
        store.add(s2)
        store.add(s3)

        // After adds: order is [s3, s2, s1] (most recent first).
        // Remove the middle (s2).
        store.remove(shelfID: s2.id)

        let all = store.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].id, s3.id, "Most recent first remains")
        XCTAssertEqual(all[1].id, s1.id, "Other survivor in correct slot")
        XCTAssertFalse(all.contains(where: { $0.id == s2.id }))
    }

    // MARK: - 5. Remove non-existent

    func testRemoveNonExistent() {
        let store = ShelfStore(backend: .inMemory)
        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        store.add(s1)

        let bogusID = ShelfID(rawValue: UUID())
        store.remove(shelfID: bogusID) // must NOT crash

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.id, s1.id)
    }

    // MARK: - 6. Move reorders + clamps

    func testMoveReorders() {
        let store = ShelfStore(backend: .inMemory)

        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        let s2 = makeShelf(name: "b", createdAt: Date(timeIntervalSince1970: 1_700_000_002))
        let s3 = makeShelf(name: "c", createdAt: Date(timeIntervalSince1970: 1_700_000_003))
        store.add(s1)
        store.add(s2)
        store.add(s3)
        // Order after adds: [s3, s2, s1]

        // Move s3 to index 2 (the back).
        store.move(shelfID: s3.id, toIndex: 2)
        XCTAssertEqual(store.all().map(\.id), [s2.id, s1.id, s3.id])

        // Out-of-bounds high → clamped to last position.
        store.move(shelfID: s2.id, toIndex: 99)
        XCTAssertEqual(store.all().map(\.id), [s1.id, s3.id, s2.id])

        // Out-of-bounds low (negative) → clamped to 0.
        store.move(shelfID: s2.id, toIndex: -5)
        XCTAssertEqual(store.all().map(\.id), [s2.id, s1.id, s3.id])

        // Moving an unknown id is a no-op.
        let bogusID = ShelfID(rawValue: UUID())
        store.move(shelfID: bogusID, toIndex: 0)
        XCTAssertEqual(store.all().map(\.id), [s2.id, s1.id, s3.id])
    }

    // MARK: - 7. Get missing

    func testGetMissing() {
        let store = ShelfStore(backend: .inMemory)
        XCTAssertNil(store.get(shelfID: ShelfID(rawValue: UUID())))

        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        store.add(s1)
        XCTAssertNil(store.get(shelfID: ShelfID(rawValue: UUID())))
    }

    // MARK: - 8. Get existing

    func testGetExisting() {
        let store = ShelfStore(backend: .inMemory)
        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        store.add(s1)

        let got = store.get(shelfID: s1.id)
        XCTAssertEqual(got, s1)
    }

    // MARK: - 9. Update appends an item + persists

    func testUpdateAddsItem() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))

        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        store.add(s1)

        let newItem = makeTextItem()
        store.update(shelfID: s1.id) { shelf in
            shelf.items.append(newItem)
        }

        // In-memory reflects update.
        let mutated = store.get(shelfID: s1.id)
        XCTAssertEqual(mutated?.items.count, 1)
        XCTAssertEqual(mutated?.items.first, newItem)

        // Persisted bytes reflect update too.
        let key = "\(prefix).shelf.\(s1.id.rawValue.uuidString)"
        guard let data = env.defaults.data(forKey: key) else {
            return XCTFail("Expected per-shelf data to be persisted after update")
        }
        let decoded = try? JSONDecoder().decode(Shelf.self, from: data)
        XCTAssertEqual(decoded?.items.first, newItem,
                       "Persisted Shelf must include the appended item")
    }

    // MARK: - 10. Update no-op for missing shelf

    func testUpdateNoOpForMissingShelf() {
        let store = ShelfStore(backend: .inMemory)

        var observerFires = 0
        store.onChange = { observerFires += 1 }

        let bogusID = ShelfID(rawValue: UUID())
        store.update(shelfID: bogusID) { shelf in
            shelf.name = "should-not-apply"
        }

        XCTAssertEqual(observerFires, 0,
                       "onChange must NOT fire for an unknown shelfID update")
        XCTAssertEqual(store.all().count, 0)
    }

    // MARK: - 11. In-memory roundtrip is NOT persistent across instances

    func testInMemoryRoundTripIsNotPersisted() {
        let store1 = ShelfStore(backend: .inMemory)
        for i in 0 ..< 3 {
            store1.add(makeShelf(
                name: "s\(i)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
            ))
        }
        XCTAssertEqual(store1.all().count, 3)

        // A fresh in-memory store sees nothing — in-memory is not durable.
        let store2 = ShelfStore(backend: .inMemory)
        XCTAssertEqual(store2.all().count, 0,
                       ".inMemory backend must NOT preserve state across instances")
    }

    // MARK: - 12. UserDefaults round-trip with mixed item kinds

    func testUserDefaultsRoundTrip() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test.prefix"

        // Three shelves, each with a different mix of all four ShelfItemKind cases.
        let shelfA = makeShelf(
            name: "A — bookmark + url",
            items: [makeBookmarkItem(), makeWebURLItem()],
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let shelfB = makeShelf(
            name: "B — text only",
            items: [makeTextItem()],
            createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let shelfC = makeShelf(
            name: "C — clipboard image",
            items: [makeClipboardImageItem(), makeTextItem(), makeWebURLItem()],
            createdAt: Date(timeIntervalSince1970: 1_700_000_300)
        )

        // First instance: write everything.
        do {
            let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
            store.add(shelfA)
            store.add(shelfB)
            store.add(shelfC)

            let all = store.all()
            XCTAssertEqual(all.count, 3)
            // After adds: [shelfC, shelfB, shelfA]
            XCTAssertEqual(all[0], shelfC)
            XCTAssertEqual(all[1], shelfB)
            XCTAssertEqual(all[2], shelfA)
        }

        // Second instance: load from the same UserDefaults+prefix.
        let store2 = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
        let restored = store2.all()
        XCTAssertEqual(restored.count, 3, "All three shelves must be restored")
        XCTAssertEqual(restored[0], shelfC, "Recency order preserved")
        XCTAssertEqual(restored[1], shelfB)
        XCTAssertEqual(restored[2], shelfA)

        // Spot check that mixed kinds round-tripped exactly.
        XCTAssertEqual(restored[2].items, shelfA.items,
                       "BookmarkRecord + webURL items round-trip exactly")
        XCTAssertEqual(restored[0].items, shelfC.items,
                       "clipboardImage + text + webURL items round-trip exactly")
    }

    // MARK: - 13. Corrupted UserDefaults recovers (graceful degradation)

    func testCorruptedUserDefaultsRecovers() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"

        // Seed with three shelves.
        let s1 = makeShelf(name: "s1", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        let s2 = makeShelf(name: "s2", createdAt: Date(timeIntervalSince1970: 1_700_000_002))
        let s3 = makeShelf(name: "s3", createdAt: Date(timeIntervalSince1970: 1_700_000_003))
        do {
            let writer = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
            writer.add(s1)
            writer.add(s2)
            writer.add(s3)
        }

        // Corrupt s2's per-shelf key with garbage bytes.
        let s2Key = "\(prefix).shelf.\(s2.id.rawValue.uuidString)"
        env.defaults.set(Data("not-valid-json-{{{".utf8), forKey: s2Key)

        // New instance must NOT crash; it should load the two valid shelves
        // and silently drop s2.
        let reader = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
        let all = reader.all()
        XCTAssertEqual(all.count, 2, "Corrupted shelf must be silently dropped")
        XCTAssertTrue(all.contains(where: { $0.id == s1.id }),
                      "Valid shelf s1 must remain")
        XCTAssertTrue(all.contains(where: { $0.id == s3.id }),
                      "Valid shelf s3 must remain")
        XCTAssertFalse(all.contains(where: { $0.id == s2.id }),
                       "Corrupted shelf s2 must NOT appear")
    }

    // MARK: - 13b. Corrupted top-level index also recovers

    func testCorruptedIndexRecovers() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"

        // Inject malformed JSON at the index key directly, with no per-shelf
        // keys present. The store should boot to an empty state without crashing.
        env.defaults.set(Data("[][NOT_JSON".utf8), forKey: "\(prefix).index")

        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
        XCTAssertEqual(store.all().count, 0,
                       "Corrupted index must result in empty load (no crash)")

        // After the recovery, the store remains usable.
        let s1 = makeShelf(name: "after-recovery",
                           createdAt: Date(timeIntervalSince1970: 1_700_000_500))
        store.add(s1)
        XCTAssertEqual(store.all().count, 1)
    }

    // MARK: - 13c. Re-adding the same ID is treated as an update, not eviction

    func testAddSameIDReplacesAndMovesToFront() {
        let store = ShelfStore(backend: .inMemory)

        // Fill to cap so that any "new add" would evict.
        var seeded: [Shelf] = []
        for i in 0 ..< ShelfStore.recentCap {
            let s = makeShelf(
                name: "seed-\(i)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
            )
            seeded.append(s)
            store.add(s)
        }
        XCTAssertEqual(store.all().count, ShelfStore.recentCap)

        // Re-add the oldest (currently at the back) with a mutated payload.
        // The store must replace + promote, NOT evict another shelf.
        let oldest = seeded[0]
        var mutated = oldest
        mutated.name = "renamed-via-readd"
        store.add(mutated)

        let all = store.all()
        XCTAssertEqual(all.count, ShelfStore.recentCap,
                       "Re-adding same ID must NOT trigger eviction")
        XCTAssertEqual(all.first?.id, oldest.id,
                       "Re-added shelf must be at the front of the recency list")
        XCTAssertEqual(all.first?.name, "renamed-via-readd",
                       "Re-added payload must replace the old payload")
    }

    // MARK: - 14. onChange fires on each mutation

    func testOnChangeFiresOnEachMutation() {
        let store = ShelfStore(backend: .inMemory)
        var fireCount = 0
        store.onChange = { fireCount += 1 }

        let s1 = makeShelf(name: "s1", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        store.add(s1)
        XCTAssertEqual(fireCount, 1, "add fires once")

        let s2 = makeShelf(name: "s2", createdAt: Date(timeIntervalSince1970: 1_700_000_002))
        store.add(s2)
        XCTAssertEqual(fireCount, 2, "second add fires once")

        store.update(shelfID: s1.id) { $0.name = "renamed" }
        XCTAssertEqual(fireCount, 3, "update on existing fires once")

        store.move(shelfID: s2.id, toIndex: 1)
        XCTAssertEqual(fireCount, 4, "move fires once")

        store.remove(shelfID: s1.id)
        XCTAssertEqual(fireCount, 5, "remove fires once")

        // No-op mutations must NOT fire onChange.
        store.remove(shelfID: ShelfID(rawValue: UUID()))
        store.update(shelfID: ShelfID(rawValue: UUID())) { $0.name = "x" }
        XCTAssertEqual(fireCount, 5,
                       "Unknown-id mutations must not fire the observer")
    }
}
