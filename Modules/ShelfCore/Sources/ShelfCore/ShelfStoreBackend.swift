// ShelfCore — pure Swift domain module for Shelf macOS app.
// No AppKit/SwiftUI imports allowed in this module.
import Foundation

/// Selects the storage strategy used by `ShelfStore`.
///
/// - `inMemory`: holds shelves in process memory only. State is not preserved
///   across `ShelfStore` instances.
/// - `userDefaults(_:keyPrefix:)`: persists to a `UserDefaults` instance under
///   keys derived from `keyPrefix`. Use a real suite (e.g.
///   `UserDefaults(suiteName: "dev.rod.shelf")`) in production and a unique
///   per-test suite (`UserDefaults(suiteName: "test.\(UUID())")`) in tests
///   to keep state isolated.
public enum ShelfStoreBackend {
    case inMemory
    case userDefaults(UserDefaults, keyPrefix: String)
}
