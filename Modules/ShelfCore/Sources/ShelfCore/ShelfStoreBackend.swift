import Foundation

public enum ShelfStoreBackend {
    case inMemory
    case userDefaults(UserDefaults, keyPrefix: String)
}
