import AppKit
import Carbon.HIToolbox
import OSLog

/// Register bare Space only while a shelf is key; Carbon avoids TCC prompts.
@MainActor
public final class HotkeyManager {
    public enum HotkeyKind: UInt32, CaseIterable {
        case showShelf = 1
        case closeFrontmost = 2
        case quickLook = 3
    }

    private static let signature: OSType = OSType(0x53484C46)

    private let log = Logger(subsystem: "dev.rod.shelf", category: "hotkey")

    private var registrations: [HotkeyKind: EventHotKeyRef] = [:]

    private var eventHandlerRef: EventHandlerRef?

    public var onShowShelf: (() -> Void)?
    public var onCloseFrontmost: (() -> Void)?
    public var onQuickLook: (() -> Void)?

    public init() {
        installCarbonEventHandler()
        register(.showShelf)
    }

    deinit {
        // Do not call @MainActor helpers from deinit; unregister Carbon refs directly.
        for (_, ref) in registrations {
            UnregisterEventHotKey(ref)
        }
        registrations.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    public func setEscEnabled(_ enabled: Bool) {
        if enabled {
            register(.closeFrontmost)
        } else {
            unregister(.closeFrontmost)
        }
    }

    public func setSpaceEnabled(_ enabled: Bool) {
        if enabled {
            register(.quickLook)
        } else {
            unregister(.quickLook)
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

    private func register(_ kind: HotkeyKind) {
        guard registrations[kind] == nil else {
            return
        }
        let (keyCode, modifiers): (UInt32, UInt32) = {
            switch kind {
            case .showShelf:       return (UInt32(kVK_Space),  UInt32(cmdKey | shiftKey))
            case .closeFrontmost:  return (UInt32(kVK_Escape), 0)
            case .quickLook:       return (UInt32(kVK_Space),  0)
            }
        }()
        let id = EventHotKeyID(signature: HotkeyManager.signature, id: kind.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref = ref else {
            log.error(
                "RegisterEventHotKey failed kind=\(kind.rawValue, privacy: .public) status=\(status, privacy: .public)"
            )
            return
        }
        registrations[kind] = ref
        log.info("Registered hotkey kind=\(kind.rawValue, privacy: .public)")
    }

    private func unregister(_ kind: HotkeyKind) {
        guard let ref = registrations.removeValue(forKey: kind) else { return }
        let status = UnregisterEventHotKey(ref)
        if status != noErr {
            log.error(
                "UnregisterEventHotKey failed kind=\(kind.rawValue, privacy: .public) status=\(status, privacy: .public)"
            )
            return
        }
        log.info("Unregistered hotkey kind=\(kind.rawValue, privacy: .public)")
    }

    private func dispatch(id: UInt32) {
        guard let kind = HotkeyKind(rawValue: id) else {
            log.error("Hotkey fired with unknown id=\(id, privacy: .public)")
            return
        }
        switch kind {
        case .showShelf:
            log.info("showShelf hotkey fired")
            onShowShelf?()
        case .closeFrontmost:
            log.info("closeFrontmost hotkey fired")
            onCloseFrontmost?()
        case .quickLook:
            log.info("quickLook hotkey fired")
            onQuickLook?()
        }
    }
}
