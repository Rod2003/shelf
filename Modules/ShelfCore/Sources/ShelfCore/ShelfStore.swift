import Foundation

public final class ShelfStore: @unchecked Sendable {
    // Keep store state under `lock`; callbacks fire after unlock so observers
    // can safely reenter the store without deadlocking.
    public var onChange: (() -> Void)? {
        get { withLock { changeHandler } }
        set { withLock { changeHandler = newValue } }
    }

    private let backend: ShelfStoreBackend
    private let lock = NSLock()
    private var shelf: ShelfGroup?
    private var changeHandler: (() -> Void)?

    public init(backend: ShelfStoreBackend) {
        self.backend = backend
        self.shelf = Self.loadFromBackend(backend)
    }

    public func set(_ shelf: ShelfGroup) {
        let callback = withLock {
            guard persist(.store(shelf)) else { return nil }
            self.shelf = shelf
            return changeHandler
        }
        callback?()
    }

    public func remove() {
        let callback = withLock {
            guard shelf != nil else {
                return nil
            }
            guard persist(.remove) else {
                return nil
            }
            shelf = nil
            return changeHandler
        }
        callback?()
    }

    public func current() -> ShelfGroup? {
        withLock { shelf }
    }

    public func update(mutate: (inout ShelfGroup) -> Void) {
        let callback = withLock {
            guard let original = shelf else {
                return nil
            }
            var updated = original
            mutate(&updated)
            guard updated != original else {
                return nil
            }
            guard persist(.store(updated)) else {
                return nil
            }
            shelf = updated
            return changeHandler
        }
        callback?()
    }

    private func persist(_ operation: PersistenceOperation) -> Bool {
        do {
            switch backend {
            case .inMemory:
                return true
            case let .userDefaults(defaults, prefix):
                switch operation {
                case .store(let shelf):
                    try Self.persistShelf(shelf, defaults: defaults, prefix: prefix)
                case .remove:
                    try Self.deleteShelf(defaults: defaults, prefix: prefix)
                }
                return true
            }
        } catch {
            assertionFailure("ShelfStore persistence failed: \(error)")
            return false
        }
    }

    private static func loadFromBackend(_ backend: ShelfStoreBackend) -> ShelfGroup? {
        switch backend {
        case .inMemory:
            return nil
        case let .userDefaults(defaults, prefix):
            if let data = defaults.data(forKey: shelfKey(prefix: prefix)),
               let decoded = try? JSONDecoder().decode(ShelfGroup.self, from: data) {
                return decoded
            }
            return migrateLegacyIndexedShelf(defaults: defaults, prefix: prefix)
        }
    }

    private static func migrateLegacyIndexedShelf(defaults: UserDefaults, prefix: String) -> ShelfGroup? {
        let indexKey = legacyIndexKey(prefix: prefix)
        guard let data = defaults.data(forKey: indexKey) else {
            return nil
        }

        guard let ids = try? JSONDecoder().decode([ShelfGroupID].self, from: data) else { return nil }
        var migratedShelf: ShelfGroup?
        var legacyKeysToRemove = [indexKey]
        for id in ids {
            let key = legacyShelfKey(prefix: prefix, id: id)
            legacyKeysToRemove.append(key)
            guard migratedShelf == nil else { continue }
            guard let shelfData = defaults.data(forKey: key) else { continue }
            guard let shelf = try? JSONDecoder().decode(ShelfGroup.self, from: shelfData) else { continue }
            migratedShelf = shelf
        }

        if let migratedShelf {
            if (try? persistShelf(migratedShelf, defaults: defaults, prefix: prefix)) != nil {
                for key in legacyKeysToRemove {
                    defaults.removeObject(forKey: key)
                }
            }
            return migratedShelf
        }

        for key in legacyKeysToRemove {
            defaults.removeObject(forKey: key)
        }
        return nil
    }

    private static func persistShelf(
        _ shelf: ShelfGroup,
        defaults: UserDefaults,
        prefix: String
    ) throws {
        let data = try JSONEncoder().encode(shelf)
        let key = shelfKey(prefix: prefix)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw PersistenceError.writeVerificationFailed(key: key)
        }
    }

    private static func deleteShelf(defaults: UserDefaults, prefix: String) throws {
        let key = shelfKey(prefix: prefix)
        defaults.removeObject(forKey: key)
        guard defaults.data(forKey: key) == nil else {
            throw PersistenceError.deleteVerificationFailed(key: key)
        }
    }

    private static func shelfKey(prefix: String) -> String {
        "\(prefix).shelf"
    }

    private static func legacyIndexKey(prefix: String) -> String {
        "\(prefix).index"
    }

    private static func legacyShelfKey(prefix: String, id: ShelfGroupID) -> String {
        "\(prefix).shelf.\(id.rawValue.uuidString)"
    }

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private extension ShelfStore {
    enum PersistenceOperation {
        case store(ShelfGroup)
        case remove
    }

    enum PersistenceError: Error, Equatable {
        case writeVerificationFailed(key: String)
        case deleteVerificationFailed(key: String)
    }
}
