import Foundation

public final class ShelfStore: @unchecked Sendable {
    // Keep shelf access under `lock`; `onChange` fires after unlock.

    public var onChange: (() -> Void)?

    private let backend: ShelfStoreBackend
    private let lock = NSLock()
    private var shelf: ShelfGroup?

    public init(backend: ShelfStoreBackend) {
        self.backend = backend
        loadFromBackend()
    }

    public func set(_ shelf: ShelfGroup) {
        lock.lock()
        self.shelf = shelf
        persistShelf(shelf)
        lock.unlock()
        onChange?()
    }

    public func remove() {
        lock.lock()
        guard shelf != nil else {
            lock.unlock()
            return
        }
        shelf = nil
        deleteShelf()
        lock.unlock()
        onChange?()
    }

    public func current() -> ShelfGroup? {
        lock.lock()
        defer { lock.unlock() }
        return shelf
    }

    public func update(mutate: (inout ShelfGroup) -> Void) {
        lock.lock()
        guard let original = shelf else {
            lock.unlock()
            return
        }
        var updated = original
        mutate(&updated)
        guard updated != original else {
            lock.unlock()
            return
        }
        shelf = updated
        persistShelf(updated)
        lock.unlock()
        onChange?()
    }

    private func loadFromBackend() {
        switch backend {
        case .inMemory:
            return
        case let .userDefaults(defaults, prefix):
            if let data = defaults.data(forKey: shelfKey(prefix: prefix)),
               let decoded = try? JSONDecoder().decode(ShelfGroup.self, from: data) {
                self.shelf = decoded
                return
            }

            migrateLegacyIndexedShelf(defaults: defaults, prefix: prefix)
        }
    }

    private func migrateLegacyIndexedShelf(defaults: UserDefaults, prefix: String) {
        guard let data = defaults.data(forKey: legacyIndexKey(prefix: prefix)) else {
            return
        }
        defer { defaults.removeObject(forKey: legacyIndexKey(prefix: prefix)) }

        guard let ids = try? JSONDecoder().decode([ShelfGroupID].self, from: data) else { return }
        var migratedShelf: ShelfGroup?
        for id in ids {
            let key = legacyShelfKey(prefix: prefix, id: id)
            defer { defaults.removeObject(forKey: key) }
            guard migratedShelf == nil else { continue }
            guard let shelfData = defaults.data(forKey: key) else { continue }
            guard let shelf = try? JSONDecoder().decode(ShelfGroup.self, from: shelfData) else { continue }
            migratedShelf = shelf
        }

        if let migratedShelf {
            self.shelf = migratedShelf
            persistShelf(migratedShelf)
        }
    }

    private func persistShelf(_ shelf: ShelfGroup) {
        guard case let .userDefaults(defaults, prefix) = backend else { return }
        guard let data = try? JSONEncoder().encode(shelf) else { return }
        defaults.set(data, forKey: shelfKey(prefix: prefix))
    }

    private func deleteShelf() {
        guard case let .userDefaults(defaults, prefix) = backend else { return }
        defaults.removeObject(forKey: shelfKey(prefix: prefix))
    }

    private func shelfKey(prefix: String) -> String {
        "\(prefix).shelf"
    }

    private func legacyIndexKey(prefix: String) -> String {
        "\(prefix).index"
    }

    private func legacyShelfKey(prefix: String, id: ShelfGroupID) -> String {
        "\(prefix).shelf.\(id.rawValue.uuidString)"
    }
}
