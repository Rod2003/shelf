import KeyboardShortcuts

/// User-rebindable global shortcuts. Defaults match the originals; the recorder
/// in Settings and persistence are handled by KeyboardShortcuts.
extension KeyboardShortcuts.Name {
    static let showShelf = Self("showShelf", default: .init(.space, modifiers: [.command, .shift]))
    static let saveReplay = Self("saveReplay", default: .init(.r, modifiers: [.control, .option]))
}
