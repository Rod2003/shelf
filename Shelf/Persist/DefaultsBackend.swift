import Foundation
import OSLog
import ShelfCore

public final class DefaultsBackend {
    public static let canonicalKeyPrefix = "dev.rod.shelf"

    public static let clipboardImagesSubpath = "Shelf/clipboard-images"

    private let log = Logger(subsystem: "dev.rod.shelf", category: "persist")
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = DefaultsBackend.canonicalKeyPrefix
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func makeShelfStore() -> ShelfStore {
        ShelfStore(backend: .userDefaults(defaults, keyPrefix: keyPrefix))
    }

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

    public func clearAll() {
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("\(keyPrefix).") {
            defaults.removeObject(forKey: key)
        }
        log.info("Cleared all keys with prefix \(self.keyPrefix, privacy: .public)")
    }
}
