// ShelfCore — pure Swift domain module for Shelf macOS app.
// No AppKit/SwiftUI imports allowed in this module.
import Foundation

/// Selects the storage strategy used by `ShelfStore`.
///
/// `ShelfStore` is a single concrete `final class`; the variation in storage
/// behavior is expressed through this enum (per Metis directive: concrete
/// types only, NO storage-protocol abstraction).
///
/// - `inMemory`: holds shelves in process memory only. State is NOT preserved
///   across `ShelfStore` instances (verified by `testInMemoryRoundTripIsNotPersisted`).
/// - `userDefaults(_:keyPrefix:)`: persists to a `UserDefaults` instance under
///   keys derived from `keyPrefix`. Use a real suite (e.g.
///   `UserDefaults(suiteName: "dev.rod.shelf")`) in production and a unique
///   per-test suite (`UserDefaults(suiteName: "test.\(UUID())")`) in tests
///   to keep state isolated.
public enum ShelfStoreBackend {
    case inMemory
    case userDefaults(UserDefaults, keyPrefix: String)
}
