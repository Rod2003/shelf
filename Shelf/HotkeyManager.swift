import AppKit
import Carbon.HIToolbox
import OSLog

/// Wraps Carbon `RegisterEventHotKey` for Shelf's three hardcoded hotkeys.
///
/// Three kinds:
///  - `.newShelf`        ⌘⇧Space — registered for app lifetime (init -> deinit)
///  - `.closeFrontmost`  Esc     — registered/unregistered as shelves gain/lose focus
///  - `.quickLook`       Space   — registered/unregistered as shelves gain/lose focus
///
/// The bare-Space hotkey is dangerous if registered globally (would steal every Space
/// keypress in every app), so registration of Esc/Space is gated by the AppCoordinator
/// via `setEscEnabled(_:)` / `setSpaceEnabled(_:)`.
///
/// Carbon's `RegisterEventHotKey` does NOT trigger a TCC permission prompt at first
/// launch — verified empirically by Dropover and the explore reports. This is the
/// reason we use the Carbon path rather than `NSEvent.addGlobalMonitorForEvents`.
@MainActor
public final class HotkeyManager {
    public enum HotkeyKind: UInt32, CaseIterable {
        case newShelf = 1        // ⌘⇧Space — app lifetime
        case closeFrontmost = 2  // Esc — gated by shelf focus
        case quickLook = 3       // Space — gated by shelf focus
    }

    // OSType('SHLF') — unique 4-char Carbon signature so other apps' hotkeys won't collide.
    private static let signature: OSType = OSType(0x53484C46)

    private let log = Logger(subsystem: "dev.rod.shelf", category: "hotkey")

    /// Active registrations indexed by kind. We hold the `EventHotKeyRef` so we can
    /// `UnregisterEventHotKey` it later, and the handler closure so the C-callback's
    /// dispatch can invoke it on the main actor.
    private var registrations: [HotkeyKind: EventHotKeyRef] = [:]

    /// One global Carbon event handler dispatches by `EventHotKeyID.id` to the right
    /// callback. Installed once at init; removed at deinit.
    private var eventHandlerRef: EventHandlerRef?

    /// Callbacks injected by AppCoordinator. Kept optional so the manager is
    /// safe to instantiate before its consumers exist.
    public var onNewShelf: (() -> Void)?
    public var onCloseFrontmost: (() -> Void)?
    public var onQuickLook: (() -> Void)?

    public init() {
        installCarbonEventHandler()
        // ⌘⇧Space stays registered for app lifetime. Esc and Space are registered
        // on demand by AppCoordinator via the gating methods below.
        register(.newShelf)
    }

    deinit {
        // deinit is implicitly nonisolated; we touch only C APIs and a private dictionary
        // we own, so this is safe. We do NOT route through the @MainActor `unregister` /
        // `unregisterAll` helpers which would require actor hopping.
        for (_, ref) in registrations {
            UnregisterEventHotKey(ref)
        }
        registrations.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    // MARK: Public gating API

    /// Enable Esc hotkey when a shelf becomes key window. Disable when no shelf is key.
    public func setEscEnabled(_ enabled: Bool) {
        if enabled {
            register(.closeFrontmost)
        } else {
            unregister(.closeFrontmost)
        }
    }

    /// Enable Space hotkey when a shelf is key with an item selected. Disable otherwise.
    /// CRITICAL: never call `setSpaceEnabled(true)` while a shelf is NOT key — it would
    /// steal every Space press in every app.
    public func setSpaceEnabled(_ enabled: Bool) {
        if enabled {
            register(.quickLook)
        } else {
            unregister(.quickLook)
        }
    }

    // MARK: Carbon plumbing

    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Pass `self` to the C-callback via opaque pointer; recovered with Unmanaged.
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        // The closure here is non-capturing, so Swift can bridge it to a C function
        // pointer (@convention(c)). All state is recovered from `userData`.
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
                // Carbon delivers events on a non-main thread under some conditions.
                // Hop to the main queue, then assume MainActor isolation to call
                // through to the manager's dispatch entry point.
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
            // Idempotent: already registered.
            return
        }
        let (keyCode, modifiers): (UInt32, UInt32) = {
            switch kind {
            case .newShelf:        return (UInt32(kVK_Space),  UInt32(cmdKey | shiftKey))
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

    /// Called from the Carbon C-callback after it has hopped to the main actor.
    private func dispatch(id: UInt32) {
        guard let kind = HotkeyKind(rawValue: id) else {
            log.error("Hotkey fired with unknown id=\(id, privacy: .public)")
            return
        }
        switch kind {
        case .newShelf:
            log.info("newShelf hotkey fired")
            onNewShelf?()
        case .closeFrontmost:
            log.info("closeFrontmost hotkey fired")
            onCloseFrontmost?()
        case .quickLook:
            log.info("quickLook hotkey fired")
            onQuickLook?()
        }
    }
}
