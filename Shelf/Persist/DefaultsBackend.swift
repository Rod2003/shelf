import Foundation
import OSLog
import ShelfCore

final class DefaultsBackend {
    static let canonicalKeyPrefix = "dev.rod.shelf"

    static let clipboardImagesSubpath = "Shelf/clipboard-images"

    private let log = Logger(subsystem: "dev.rod.shelf", category: "persist")
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = DefaultsBackend.canonicalKeyPrefix
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func makeShelfStore() -> ShelfStore {
        ShelfStore(backend: .userDefaults(defaults, keyPrefix: keyPrefix))
    }

    static func clipboardImagesDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL? {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport.appendingPathComponent(
            clipboardImagesSubpath,
            isDirectory: true
        )
    }

    static func clipboardImageURL(
        filename: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let directory = clipboardImagesDirectoryURL(fileManager: fileManager) else {
            return nil
        }
        let url = directory.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func ensureApplicationSupport() -> URL? {
        let fm = FileManager.default
        guard let target = Self.clipboardImagesDirectoryURL(fileManager: fm) else {
            log.error("Application Support URL unavailable")
            return nil
        }
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

    func clearAll() {
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("\(keyPrefix).") {
            defaults.removeObject(forKey: key)
        }
        log.info("Cleared all keys with prefix \(self.keyPrefix, privacy: .public)")
    }
}
