import AppKit
import Carbon.HIToolbox
import OSLog

/// Registers the global show-shelf hotkey (Cmd+Shift+Space); Carbon avoids TCC
/// prompts. Esc and Space are handled locally by the panel while it is key.
@MainActor
public final class HotkeyManager {
    private static let signature: OSType = OSType(0x53484C46)
    private static let showShelfHotKeyID: UInt32 = 1

    private let log = Logger(subsystem: "dev.rod.shelf", category: "hotkey")

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    public var onShowShelf: (() -> Void)?

    public init() {
        installCarbonEventHandler()
        registerShowShelfHotkey()
    }

    deinit {
        // Do not call @MainActor helpers from deinit; unregister Carbon refs directly.
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
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

    private func dispatch(id: UInt32) {
        guard id == Self.showShelfHotKeyID else {
            log.error("Hotkey fired with unknown id=\(id, privacy: .public)")
            return
        }
        log.info("showShelf hotkey fired")
        onShowShelf?()
    }
}
