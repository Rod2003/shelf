import XCTest
@testable import ShelfCore

final class ShelfStoreTests: XCTestCase {
    private func makeIsolatedDefaults(file: StaticString = #file, line: UInt = #line)
        -> (defaults: UserDefaults, suiteName: String)
    {
        let suiteName = "test.shelfstore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("UserDefaults(suiteName:) returned nil", file: file, line: line)
            return (UserDefaults.standard, suiteName)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
    private func cleanupDefaults(_ defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeShelf(
        name: String,
        items: [ShelfItem] = [],
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) -> ShelfGroup {
        ShelfGroup(
            id: ShelfGroupID(rawValue: UUID()),
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

    func testAddSingleShelf() {
        let store = ShelfStore(backend: .inMemory)
        XCTAssertEqual(store.all().count, 0, "Fresh store starts empty")

        let shelf = makeShelf(name: "First", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.add(shelf)

        let all = store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first, shelf)
    }

    func testAddPastCapEvictsOldest() {
        let store = ShelfStore(backend: .inMemory)
        var added: [ShelfGroup] = []
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
        XCTAssertFalse(all.contains(where: { $0.id == added[0].id }),
                       "Oldest shelf must be evicted")
        XCTAssertEqual(all[0], added[5], "Most recent at front")
        XCTAssertEqual(all[4], added[1], "Oldest surviving at tail")
    }

    func testEvictionDeletesUserDefaultsKey() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))

        var added: [ShelfGroup] = []
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
        let lastID = added[5].id
        let lastKey = "\(prefix).shelf.\(lastID.rawValue.uuidString)"
        XCTAssertNotNil(env.defaults.data(forKey: lastKey),
                        "Newest shelf's key must still be present")
    }

    func testRemoveExisting() {
        let store = ShelfStore(backend: .inMemory)

        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        let s2 = makeShelf(name: "b", createdAt: Date(timeIntervalSince1970: 1_700_000_002))
        let s3 = makeShelf(name: "c", createdAt: Date(timeIntervalSince1970: 1_700_000_003))
        store.add(s1)
        store.add(s2)
        store.add(s3)
        store.remove(shelfID: s2.id)

        let all = store.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].id, s3.id, "Most recent first remains")
        XCTAssertEqual(all[1].id, s1.id, "Other survivor in correct slot")
        XCTAssertFalse(all.contains(where: { $0.id == s2.id }))
    }

    func testRemoveNonExistent() {
        let store = ShelfStore(backend: .inMemory)
        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        store.add(s1)

        let bogusID = ShelfGroupID(rawValue: UUID())
        store.remove(shelfID: bogusID)

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.id, s1.id)
    }

    func testMoveReorders() {
        let store = ShelfStore(backend: .inMemory)

        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        let s2 = makeShelf(name: "b", createdAt: Date(timeIntervalSince1970: 1_700_000_002))
        let s3 = makeShelf(name: "c", createdAt: Date(timeIntervalSince1970: 1_700_000_003))
        store.add(s1)
        store.add(s2)
        store.add(s3)
        store.move(shelfID: s3.id, toIndex: 2)
        XCTAssertEqual(store.all().map(\.id), [s2.id, s1.id, s3.id])
        store.move(shelfID: s2.id, toIndex: 99)
        XCTAssertEqual(store.all().map(\.id), [s1.id, s3.id, s2.id])
        store.move(shelfID: s2.id, toIndex: -5)
        XCTAssertEqual(store.all().map(\.id), [s2.id, s1.id, s3.id])
        let bogusID = ShelfGroupID(rawValue: UUID())
        store.move(shelfID: bogusID, toIndex: 0)
        XCTAssertEqual(store.all().map(\.id), [s2.id, s1.id, s3.id])
    }

    func testGetMissing() {
        let store = ShelfStore(backend: .inMemory)
        XCTAssertNil(store.get(shelfID: ShelfGroupID(rawValue: UUID())))

        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        store.add(s1)
        XCTAssertNil(store.get(shelfID: ShelfGroupID(rawValue: UUID())))
    }

    func testGetExisting() {
        let store = ShelfStore(backend: .inMemory)
        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        store.add(s1)

        let got = store.get(shelfID: s1.id)
        XCTAssertEqual(got, s1)
    }

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
        let mutated = store.get(shelfID: s1.id)
        XCTAssertEqual(mutated?.items.count, 1)
        XCTAssertEqual(mutated?.items.first, newItem)
        let key = "\(prefix).shelf.\(s1.id.rawValue.uuidString)"
        guard let data = env.defaults.data(forKey: key) else {
            return XCTFail("Expected per-shelf data to be persisted after update")
        }
        let decoded = try? JSONDecoder().decode(ShelfGroup.self, from: data)
        XCTAssertEqual(decoded?.items.first, newItem,
                       "Persisted ShelfGroup must include the appended item")
    }

    func testUpdateNoOpForMissingShelf() {
        let store = ShelfStore(backend: .inMemory)

        var observerFires = 0
        store.onChange = { observerFires += 1 }

        let bogusID = ShelfGroupID(rawValue: UUID())
        store.update(shelfID: bogusID) { shelf in
            shelf.name = "should-not-apply"
        }

        XCTAssertEqual(observerFires, 0,
                       "onChange must NOT fire for an unknown shelfID update")
        XCTAssertEqual(store.all().count, 0)
    }

    func testUpdateWithNoOpMutationDoesNotFireOnChange() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))

        let s1 = makeShelf(name: "a", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        store.add(s1)

        var observerFires = 0
        store.onChange = { observerFires += 1 }
        store.update(shelfID: s1.id) { _ in }
        XCTAssertEqual(observerFires, 0,
                       "Empty mutation closure must be treated as a no-op")

        store.update(shelfID: s1.id) { shelf in
            _ = shelf.name
        }
        XCTAssertEqual(observerFires, 0,
                       "Read-only mutation closure must be treated as a no-op")
        store.update(shelfID: s1.id) { shelf in
            shelf.name = "renamed"
        }
        XCTAssertEqual(observerFires, 1, "Real mutation fires observer once")
    }

    func testInMemoryRoundTripIsNotPersisted() {
        let store1 = ShelfStore(backend: .inMemory)
        for i in 0 ..< 3 {
            store1.add(makeShelf(
                name: "s\(i)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
            ))
        }
        XCTAssertEqual(store1.all().count, 3)
        let store2 = ShelfStore(backend: .inMemory)
        XCTAssertEqual(store2.all().count, 0,
                       ".inMemory backend must NOT preserve state across instances")
    }

    func testUserDefaultsRoundTrip() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test.prefix"
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
        do {
            let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
            store.add(shelfA)
            store.add(shelfB)
            store.add(shelfC)

            let all = store.all()
            XCTAssertEqual(all.count, 3)
            XCTAssertEqual(all[0], shelfC)
            XCTAssertEqual(all[1], shelfB)
            XCTAssertEqual(all[2], shelfA)
        }
        let store2 = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
        let restored = store2.all()
        XCTAssertEqual(restored.count, 3, "All three shelves must be restored")
        XCTAssertEqual(restored[0], shelfC, "Recency order preserved")
        XCTAssertEqual(restored[1], shelfB)
        XCTAssertEqual(restored[2], shelfA)
        XCTAssertEqual(restored[2].items, shelfA.items,
                       "BookmarkRecord + webURL items round-trip exactly")
        XCTAssertEqual(restored[0].items, shelfC.items,
                       "clipboardImage + text + webURL items round-trip exactly")
    }

    func testCorruptedUserDefaultsRecovers() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        let s1 = makeShelf(name: "s1", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        let s2 = makeShelf(name: "s2", createdAt: Date(timeIntervalSince1970: 1_700_000_002))
        let s3 = makeShelf(name: "s3", createdAt: Date(timeIntervalSince1970: 1_700_000_003))
        do {
            let writer = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
            writer.add(s1)
            writer.add(s2)
            writer.add(s3)
        }
        let s2Key = "\(prefix).shelf.\(s2.id.rawValue.uuidString)"
        env.defaults.set(Data("not-valid-json-{{{".utf8), forKey: s2Key)
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

    func testCorruptedIndexRecovers() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        env.defaults.set(Data("[][NOT_JSON".utf8), forKey: "\(prefix).index")

        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
        XCTAssertEqual(store.all().count, 0,
                       "Corrupted index must result in empty load (no crash)")
        let s1 = makeShelf(name: "after-recovery",
                           createdAt: Date(timeIntervalSince1970: 1_700_000_500))
        store.add(s1)
        XCTAssertEqual(store.all().count, 1)
    }

    func testAddSameIDReplacesAndMovesToFront() {
        let store = ShelfStore(backend: .inMemory)
        var seeded: [ShelfGroup] = []
        for i in 0 ..< ShelfStore.recentCap {
            let s = makeShelf(
                name: "seed-\(i)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
            )
            seeded.append(s)
            store.add(s)
        }
        XCTAssertEqual(store.all().count, ShelfStore.recentCap)
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
        store.remove(shelfID: ShelfGroupID(rawValue: UUID()))
        store.update(shelfID: ShelfGroupID(rawValue: UUID())) { $0.name = "x" }
        XCTAssertEqual(fireCount, 5,
                       "Unknown-id mutations must not fire the observer")
    }
}
