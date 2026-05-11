// ShelfCore — pure Swift domain module for Shelf macOS app.
// No AppKit/SwiftUI imports allowed in this module.
import Foundation

/// Stores up to `recentCap` recent `Shelf` values in either an in-memory
/// dictionary or a `UserDefaults` suite, with the oldest shelf evicted when
/// the cap is exceeded.
///
/// ## Recency ordering
/// `ShelfStore` maintains an explicit ordered list of `ShelfID`s (the "index")
/// representing recency, where index 0 is most-recently-used. `add(_:)`
/// inserts at the front; `move(shelfID:toIndex:)` reorders within the list
/// (clamping out-of-bounds indices); eviction removes from the tail.
/// `all()` returns shelves in this order.
///
/// ## Persistence (UserDefaults backend)
/// Two key shapes under `keyPrefix`:
/// - `"\(prefix).index"` — JSON-encoded `[ShelfID]` recency list
/// - `"\(prefix).shelf.\(uuid)"` — JSON-encoded `Shelf`
///
/// On `init(backend:)`, if the backend is `.userDefaults`, the store reads
/// the index and decodes each per-shelf key. A per-shelf key with malformed
/// JSON is dropped (graceful degradation; no crash).
///
/// ## Thread safety
/// All public methods take an `NSLock` around the underlying state, so
/// `ShelfStore` may be called from any thread.
///
/// ## Observation
/// `onChange` is a single optional callback invoked after every mutation
/// (`add`, `remove`, `move`, `update` when something actually changes).
public final class ShelfStore: @unchecked Sendable {
    // `@unchecked Sendable`: all mutable state is guarded by the `NSLock`
    // below, so the compiler's stricter Sendable check is replaced with a
    // hand-maintained invariant — every public method takes the lock
    // before touching `shelves` / `order`, and `onChange` is invoked only
    // after the lock has been released.

    /// Maximum number of shelves retained at once. Not user-configurable.
    public static let recentCap: Int = 5

    /// Invoked after every state-changing mutation. Single optional
    /// observer; for richer observation, wrap in a higher layer.
    public var onChange: (() -> Void)?

    private let backend: ShelfStoreBackend
    private let lock = NSLock()
    private var shelves: [ShelfID: Shelf] = [:]
    /// Recency-ordered list of IDs; element 0 is most-recently-used.
    private var order: [ShelfID] = []

    /// Initialize a store with the given backend. For `.userDefaults`
    /// backends, the on-disk state is loaded immediately; malformed
    /// per-shelf keys are skipped (no crash).
    public init(backend: ShelfStoreBackend) {
        self.backend = backend
        loadFromBackend()
    }

    // MARK: - Public API

    /// Add a new shelf. Inserts at the front of the recency list.
    /// If the store would exceed `recentCap`, the oldest shelf is evicted
    /// (and its persisted data deleted for `.userDefaults` backends).
    /// If a shelf with the same id already exists, it is replaced in place
    /// and moved to the front (no eviction in that case).
    public func add(_ shelf: Shelf) {
        lock.lock()
        if shelves[shelf.id] != nil {
            // Replace in place + move to front; no eviction.
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

    /// Remove a shelf by id. No-op if not present.
    public func remove(shelfID: ShelfID) {
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

    /// Move a shelf to a new position in the recency list. The destination
    /// index is clamped to `[0, count - 1]`. No-op if `shelfID` is unknown.
    public func move(shelfID: ShelfID, toIndex: Int) {
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

    /// Returns the shelf with the given id, or nil if missing.
    public func get(shelfID: ShelfID) -> Shelf? {
        lock.lock()
        defer { lock.unlock() }
        return shelves[shelfID]
    }

    /// Returns shelves in recency order (most-recently-used first).
    public func all() -> [Shelf] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { shelves[$0] }
    }

    /// Mutate an existing shelf in place. No-op (and `onChange` does NOT
    /// fire) if `shelfID` is not present, or if `mutate` leaves the shelf
    /// `Equatable`-equal to its pre-mutation value — that suppresses
    /// redundant disk writes and observer notifications when the caller's
    /// closure ends up being a logical no-op.
    public func update(shelfID: ShelfID, mutate: (inout Shelf) -> Void) {
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

    // MARK: - Backend dispatch (private)

    private func loadFromBackend() {
        switch backend {
        case .inMemory:
            return
        case let .userDefaults(defaults, prefix):
            guard let data = defaults.data(forKey: indexKey(prefix: prefix)) else {
                return
            }
            guard let ids = try? JSONDecoder().decode([ShelfID].self, from: data) else {
                // Malformed index: graceful start-from-empty.
                return
            }
            var loadedOrder: [ShelfID] = []
            var loadedShelves: [ShelfID: Shelf] = [:]
            for id in ids {
                let key = shelfKey(prefix: prefix, id: id)
                guard let shelfData = defaults.data(forKey: key) else { continue }
                guard let shelf = try? JSONDecoder().decode(Shelf.self, from: shelfData) else {
                    // Malformed per-shelf key: skip (graceful degradation).
                    continue
                }
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

    private func persistShelf(_ shelf: Shelf) {
        guard case let .userDefaults(defaults, prefix) = backend else { return }
        guard let data = try? JSONEncoder().encode(shelf) else { return }
        defaults.set(data, forKey: shelfKey(prefix: prefix, id: shelf.id))
    }

    private func deleteShelfKey(_ id: ShelfID) {
        guard case let .userDefaults(defaults, prefix) = backend else { return }
        defaults.removeObject(forKey: shelfKey(prefix: prefix, id: id))
    }

    // MARK: - Key formatting

    private func indexKey(prefix: String) -> String {
        "\(prefix).index"
    }

    private func shelfKey(prefix: String, id: ShelfID) -> String {
        "\(prefix).shelf.\(id.rawValue.uuidString)"
    }
}
