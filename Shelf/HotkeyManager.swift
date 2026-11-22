import AppKit
import Carbon.HIToolbox
import OSLog

/// Registers the global show-shelf hotkey (Cmd+Shift+Space) and, while Replay is
/// on, the save-replay hotkey (Ctrl+Option+R); Carbon avoids TCC prompts.
/// Esc and Space are handled locally by the panel while it is key.
@MainActor
final class HotkeyManager {
    private static let signature: OSType = OSType(0x53484C46)
    private static let showShelfHotKeyID: UInt32 = 1
    private static let saveReplayHotKeyID: UInt32 = 2
    static let saveReplayShortcutLabel = "⌃⌥R"

    private let log = Logger(subsystem: "dev.rod.shelf", category: "hotkey")

    private var hotKeyRef: EventHotKeyRef?
    private var saveReplayHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var onShowShelf: (() -> Void)?
    var onSaveReplay: (() -> Void)?

    init() {
        installCarbonEventHandler()
        registerShowShelfHotkey()
    }

    deinit {
        // Do not call @MainActor helpers from deinit; unregister Carbon refs directly.
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let saveReplayHotKeyRef {
            UnregisterEventHotKey(saveReplayHotKeyRef)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData, let eventRef = eventRef else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyID = EventHotKeyID()
                let getStatus = GetEventParameter(
                    eventRef,
                    OSType(kEventParamDirectObject),
                    OSType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard getStatus == noErr else { return getStatus }
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let mgr = Unmanaged<HotkeyManager>
                            .fromOpaque(userData)
                            .takeUnretainedValue()
                        mgr.dispatch(id: id)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            ctx,
            &eventHandlerRef
        )
        if status != noErr {
            log.error("InstallEventHandler failed: status=\(status, privacy: .public)")
        }
    }

    private func registerShowShelfHotkey() {
        guard hotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: HotkeyManager.signature, id: Self.showShelfHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey failed status=\(status, privacy: .public)")
            return
        }
        hotKeyRef = ref
        log.info("Registered show-shelf hotkey")
    }

    /// Only claimed while Replay is on, so the combo isn't swallowed globally otherwise.
    func setSaveReplayEnabled(_ enabled: Bool) {
        if !enabled {
            if let saveReplayHotKeyRef { UnregisterEventHotKey(saveReplayHotKeyRef) }
            saveReplayHotKeyRef = nil
            return
        }
        guard saveReplayHotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: HotkeyManager.signature, id: Self.saveReplayHotKeyID)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(controlKey | optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &saveReplayHotKeyRef
        )
        if status != noErr {
            log.error("RegisterEventHotKey(saveReplay) failed status=\(status, privacy: .public)")
        }
    }

    private func dispatch(id: UInt32) {
        switch id {
        case Self.showShelfHotKeyID:
            log.info("showShelf hotkey fired")
            onShowShelf?()
        case Self.saveReplayHotKeyID:
            log.info("saveReplay hotkey fired")
            onSaveReplay?()
        default:
            log.error("Hotkey fired with unknown id=\(id, privacy: .public)")
        }
    }
}
