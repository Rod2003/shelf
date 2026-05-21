import Foundation

public final class ShelfStore: @unchecked Sendable {
    // Keep every shelves/order access under `lock`; `onChange` fires after unlock.

    public static let recentCap: Int = 5

    public var onChange: (() -> Void)?

    private let backend: ShelfStoreBackend
    private let lock = NSLock()
    private var shelves: [ShelfGroupID: ShelfGroup] = [:]
    private var order: [ShelfGroupID] = []

    public init(backend: ShelfStoreBackend) {
        self.backend = backend
        loadFromBackend()
    }

    public func add(_ shelf: ShelfGroup) {
        lock.lock()
        if shelves[shelf.id] != nil {
            shelves[shelf.id] = shelf
            order.removeAll { $0 == shelf.id }
            order.insert(shelf.id, at: 0)
            persistShelf(shelf)
            persistIndex()
        } else {
            shelves[shelf.id] = shelf
            order.insert(shelf.id, at: 0)
            persistShelf(shelf)
            while order.count > Self.recentCap {
                let evicted = order.removeLast()
                shelves.removeValue(forKey: evicted)
                deleteShelfKey(evicted)
            }
            persistIndex()
        }
        lock.unlock()
        onChange?()
    }

    public func remove(shelfID: ShelfGroupID) {
        lock.lock()
        guard shelves.removeValue(forKey: shelfID) != nil else {
            lock.unlock()
            return
        }
        order.removeAll { $0 == shelfID }
        deleteShelfKey(shelfID)
        persistIndex()
        lock.unlock()
        onChange?()
    }

    public func move(shelfID: ShelfGroupID, toIndex: Int) {
        lock.lock()
        guard let currentIndex = order.firstIndex(of: shelfID) else {
            lock.unlock()
            return
        }
        order.remove(at: currentIndex)
        let clamped = max(0, min(toIndex, order.count))
        order.insert(shelfID, at: clamped)
        persistIndex()
        lock.unlock()
        onChange?()
    }

    public func get(shelfID: ShelfGroupID) -> ShelfGroup? {
        lock.lock()
        defer { lock.unlock() }
        return shelves[shelfID]
    }

    public func all() -> [ShelfGroup] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { shelves[$0] }
    }

    public func update(shelfID: ShelfGroupID, mutate: (inout ShelfGroup) -> Void) {
        lock.lock()
        guard let original = shelves[shelfID] else {
            lock.unlock()
            return
        }
        var shelf = original
        mutate(&shelf)
        guard shelf != original else {
            lock.unlock()
            return
        }
        shelves[shelfID] = shelf
        persistShelf(shelf)
        lock.unlock()
        onChange?()
    }

    private func loadFromBackend() {
        switch backend {
        case .inMemory:
            return
        case let .userDefaults(defaults, prefix):
            guard let data = defaults.data(forKey: indexKey(prefix: prefix)) else {
                return
            }
            guard let ids = try? JSONDecoder().decode([ShelfGroupID].self, from: data) else { return }
            var loadedOrder: [ShelfGroupID] = []
            var loadedShelves: [ShelfGroupID: ShelfGroup] = [:]
            for id in ids {
                let key = shelfKey(prefix: prefix, id: id)
                guard let shelfData = defaults.data(forKey: key) else { continue }
                guard let shelf = try? JSONDecoder().decode(ShelfGroup.self, from: shelfData) else { continue }
                loadedOrder.append(id)
                loadedShelves[id] = shelf
            }
            self.order = loadedOrder
            self.shelves = loadedShelves
        }
    }

    private func persistIndex() {
        guard case let .userDefaults(defaults, prefix) = backend else { return }
        guard let data = try? JSONEncoder().encode(order) else { return }
        defaults.set(data, forKey: indexKey(prefix: prefix))
    }

    private func persistShelf(_ shelf: ShelfGroup) {
        guard case let .userDefaults(defaults, prefix) = backend else { return }
        guard let data = try? JSONEncoder().encode(shelf) else { return }
        defaults.set(data, forKey: shelfKey(prefix: prefix, id: shelf.id))
    }

    private func deleteShelfKey(_ id: ShelfGroupID) {
        guard case let .userDefaults(defaults, prefix) = backend else { return }
        defaults.removeObject(forKey: shelfKey(prefix: prefix, id: id))
    }

    private func indexKey(prefix: String) -> String {
        "\(prefix).index"
    }

    private func shelfKey(prefix: String, id: ShelfGroupID) -> String {
        "\(prefix).shelf.\(id.rawValue.uuidString)"
    }
}
