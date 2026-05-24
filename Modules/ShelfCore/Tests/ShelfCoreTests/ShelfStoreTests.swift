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
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
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

    func testFreshStoreStartsEmpty() {
        let store = ShelfStore(backend: .inMemory)
        XCTAssertNil(store.current())
    }

    func testSetStoresCurrentShelf() {
        let store = ShelfStore(backend: .inMemory)
        let shelf = makeShelf(name: "First")

        store.set(shelf)

        XCTAssertEqual(store.current(), shelf)
    }

    func testSetReplacesCurrentShelf() {
        let store = ShelfStore(backend: .inMemory)
        let first = makeShelf(name: "first")
        let second = makeShelf(name: "second")

        store.set(first)
        store.set(second)

        XCTAssertEqual(store.current(), second)
    }

    func testRemoveCurrentShelf() {
        let store = ShelfStore(backend: .inMemory)
        store.set(makeShelf(name: "to-remove"))

        store.remove()

        XCTAssertNil(store.current())
    }

    func testRemoveWhenEmptyDoesNotFireOnChange() {
        let store = ShelfStore(backend: .inMemory)
        var observerFires = 0
        store.onChange = { observerFires += 1 }

        store.remove()

        XCTAssertEqual(observerFires, 0)
    }

    func testUpdateAddsItem() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
        store.set(makeShelf(name: "current"))

        let newItem = makeTextItem()
        store.update { shelf in
            shelf.items.append(newItem)
        }

        XCTAssertEqual(store.current()?.items, [newItem])
        let key = "\(prefix).shelf"
        guard let data = env.defaults.data(forKey: key) else {
            return XCTFail("Expected shelf data to be persisted after update")
        }
        let decoded = try? JSONDecoder().decode(ShelfGroup.self, from: data)
        XCTAssertEqual(decoded?.items, [newItem])
    }

    func testUpdateNoOpForEmptyStore() {
        let store = ShelfStore(backend: .inMemory)
        var observerFires = 0
        store.onChange = { observerFires += 1 }

        store.update { shelf in
            shelf.name = "should-not-apply"
        }

        XCTAssertEqual(observerFires, 0)
        XCTAssertNil(store.current())
    }

    func testUpdateWithNoOpMutationDoesNotFireOnChange() {
        let store = ShelfStore(backend: .inMemory)
        store.set(makeShelf(name: "current"))

        var observerFires = 0
        store.onChange = { observerFires += 1 }

        store.update { _ in }
        store.update { shelf in
            _ = shelf.name
        }

        XCTAssertEqual(observerFires, 0)

        store.update { shelf in
            shelf.name = "renamed"
        }
        XCTAssertEqual(observerFires, 1)
    }

    func testInMemoryRoundTripIsNotPersisted() {
        let store1 = ShelfStore(backend: .inMemory)
        store1.set(makeShelf(name: "current"))

        let store2 = ShelfStore(backend: .inMemory)

        XCTAssertNil(store2.current())
    }

    func testUserDefaultsRoundTrip() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test.prefix"
        let shelf = makeShelf(
            name: "Current",
            items: [makeBookmarkItem(), makeWebURLItem(), makeTextItem(), makeClipboardImageItem()]
        )

        do {
            let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
            store.set(shelf)
            XCTAssertEqual(store.current(), shelf)
        }

        let restoredStore = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))
        XCTAssertEqual(restoredStore.current(), shelf)
    }

    func testCorruptedUserDefaultsRecoversEmpty() {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        env.defaults.set(Data("not-valid-json-{{{".utf8), forKey: "\(prefix).shelf")

        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))

        XCTAssertNil(store.current())
    }

    func testMigratesNewestLegacyIndexedShelf() throws {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        let older = makeShelf(name: "older", createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        let newer = makeShelf(name: "newer", createdAt: Date(timeIntervalSince1970: 1_700_000_002))
        env.defaults.set(
            try JSONEncoder().encode([newer.id, older.id]),
            forKey: "\(prefix).index"
        )
        env.defaults.set(
            try JSONEncoder().encode(older),
            forKey: "\(prefix).shelf.\(older.id.rawValue.uuidString)"
        )
        env.defaults.set(
            try JSONEncoder().encode(newer),
            forKey: "\(prefix).shelf.\(newer.id.rawValue.uuidString)"
        )

        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))

        XCTAssertEqual(store.current(), newer)
        XCTAssertNotNil(env.defaults.data(forKey: "\(prefix).shelf"))
        XCTAssertNil(env.defaults.data(forKey: "\(prefix).index"))
        XCTAssertNil(env.defaults.data(forKey: "\(prefix).shelf.\(older.id.rawValue.uuidString)"))
        XCTAssertNil(env.defaults.data(forKey: "\(prefix).shelf.\(newer.id.rawValue.uuidString)"))
    }

    func testMigratesFirstValidLegacyShelf() throws {
        let env = makeIsolatedDefaults()
        defer { cleanupDefaults(env.defaults, suiteName: env.suiteName) }

        let prefix = "test"
        let corruptedID = ShelfGroupID(rawValue: UUID())
        let fallback = makeShelf(name: "fallback")
        env.defaults.set(
            try JSONEncoder().encode([corruptedID, fallback.id]),
            forKey: "\(prefix).index"
        )
        env.defaults.set(
            Data("not-valid-json-{{{".utf8),
            forKey: "\(prefix).shelf.\(corruptedID.rawValue.uuidString)"
        )
        env.defaults.set(
            try JSONEncoder().encode(fallback),
            forKey: "\(prefix).shelf.\(fallback.id.rawValue.uuidString)"
        )

        let store = ShelfStore(backend: .userDefaults(env.defaults, keyPrefix: prefix))

        XCTAssertEqual(store.current(), fallback)
        XCTAssertNil(env.defaults.data(forKey: "\(prefix).index"))
        XCTAssertNil(env.defaults.data(forKey: "\(prefix).shelf.\(corruptedID.rawValue.uuidString)"))
        XCTAssertNil(env.defaults.data(forKey: "\(prefix).shelf.\(fallback.id.rawValue.uuidString)"))
    }

    func testOnChangeFiresOnEachMutation() {
        let store = ShelfStore(backend: .inMemory)
        var fireCount = 0
        store.onChange = { fireCount += 1 }

        store.set(makeShelf(name: "current"))
        XCTAssertEqual(fireCount, 1, "set fires once")

        store.update { $0.name = "renamed" }
        XCTAssertEqual(fireCount, 2, "update fires once")

        store.remove()
        XCTAssertEqual(fireCount, 3, "remove fires once")

        store.remove()
        store.update { $0.name = "missing" }
        XCTAssertEqual(fireCount, 3, "empty-store mutations must not fire the observer")
    }
}
