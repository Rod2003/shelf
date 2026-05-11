import Foundation
import OSLog
import ShelfCore

/// Production-side wrapper around `ShelfCore.ShelfStore`.
///
/// `DefaultsBackend` owns:
/// - the canonical `UserDefaults` instance used by the app (default: `.standard`),
/// - the canonical key prefix (`dev.rod.shelf`, matching the bundle ID),
/// - the `~/Library/Application Support/Shelf/clipboard-images/` directory
///   ensured on first launch.
///
/// It is deliberately a thin app-layer wrapper: all storage logic lives in
/// `ShelfCore.ShelfStore`.
///
/// When the app is code-signed and notarized, migrate to an App Group
/// container (e.g. `group.dev.rod.shelf`) so a Shelf widget extension can
/// share the same `UserDefaults` suite and Application Support tree.
public final class DefaultsBackend {

    /// Canonical key prefix for production. Matches the app bundle identifier
    /// (`dev.rod.shelf`); ShelfStore will write keys of the form
    /// `dev.rod.shelf.index` and `dev.rod.shelf.shelf.<uuid>`.
    public static let canonicalKeyPrefix = "dev.rod.shelf"

    /// Subpath under Application Support reserved for clipboard image blobs
    /// (PNG/JPEG payloads referenced by `ShelfItem.image` records). Created
    /// on first launch by `ensureApplicationSupport()`.
    public static let clipboardImagesSubpath = "Shelf/clipboard-images"

    private let log = Logger(subsystem: "dev.rod.shelf", category: "persist")
    private let defaults: UserDefaults
    private let keyPrefix: String

    /// Initialize with an explicit `UserDefaults` instance and key prefix.
    /// Defaults to `.standard` and `canonicalKeyPrefix` for production use;
    /// tests should pass a per-test suite (e.g.
    /// `UserDefaults(suiteName: "test.\(UUID())")`) and a unique prefix.
    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = DefaultsBackend.canonicalKeyPrefix
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    /// Construct a fresh `ShelfStore` bound to this backend's UserDefaults
    /// suite and key prefix. The store loads existing on-disk state during
    /// its initializer (see `ShelfStore.init(backend:)`).
    public func makeShelfStore() -> ShelfStore {
        ShelfStore(backend: .userDefaults(defaults, keyPrefix: keyPrefix))
    }

    /// Ensure `~/Library/Application Support/Shelf/clipboard-images/` exists.
    /// Idempotent — safe to call on every launch. Returns the resolved URL
    /// of the clipboard-images directory on success, or `nil` if the user's
    /// Application Support URL is unavailable or the directory could not be
    /// created.
    ///
    /// Errors are logged via OSLog (subsystem `dev.rod.shelf`,
    /// category `persist`) but are non-fatal: the app must still launch even
    /// if the directory cannot be created (e.g. read-only home).
    @discardableResult
    public func ensureApplicationSupport() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            log.error("Application Support URL unavailable")
            return nil
        }
        let target = appSupport.appendingPathComponent(
            Self.clipboardImagesSubpath,
            isDirectory: true
        )
        do {
            try fm.createDirectory(
                at: target,
                withIntermediateDirectories: true
            )
            log.info("Application Support tree ready at \(target.path, privacy: .public)")
            return target
        } catch {
            log.error("Failed to create App Support directory: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Helper for app shutdown / tests; clears all shelf-prefixed keys for
    /// the configured `UserDefaults` suite. Removes any key whose name
    /// begins with `"\(keyPrefix)."` — matching both the `.index` key and
    /// per-shelf `.shelf.<uuid>` keys written by `ShelfStore`.
    public func clearAll() {
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("\(keyPrefix).") {
            defaults.removeObject(forKey: key)
        }
        log.info("Cleared all keys with prefix \(self.keyPrefix, privacy: .public)")
    }
}
