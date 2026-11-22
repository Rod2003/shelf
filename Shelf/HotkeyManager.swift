import KeyboardShortcuts
import OSLog

/// Bridges the user-rebindable global shortcuts to app actions. KeyboardShortcuts
/// owns registration, persistence, and the recorder UI (see Settings); this just
/// routes key-downs and gates the save-replay shortcut to when Replay is on.
@MainActor
final class HotkeyManager {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "hotkey")

    var onShowShelf: (() -> Void)?
    var onSaveReplay: (() -> Void)?

    init() {
        KeyboardShortcuts.onKeyDown(for: .showShelf) { [weak self] in
            self?.log.info("showShelf shortcut fired")
            self?.onShowShelf?()
        }
        KeyboardShortcuts.onKeyDown(for: .saveReplay) { [weak self] in
            self?.log.info("saveReplay shortcut fired")
            self?.onSaveReplay?()
        }
    }

    /// Only listen for the save-replay shortcut while Replay is on, so the combo
    /// is free for other apps otherwise.
    func setSaveReplayEnabled(_ enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(.saveReplay)
        } else {
            KeyboardShortcuts.disable(.saveReplay)
        }
    }
}
