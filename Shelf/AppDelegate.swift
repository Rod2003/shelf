import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")

    /// Strong reference to the app's single coordinator. Held here because
    /// AppDelegate is the canonical owner of process-wide app state.
    /// `coordinator?.teardown()` is called from `applicationWillTerminate`.
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Shelf launching (pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public))")

        // CRITICAL: Per Spike B findings, .accessory policy is required for .nonactivatingPanel
        // to actually keep the app non-activating when shelves are shown. Without this,
        // showing a shelf would activate Shelf and steal focus from the user's frontmost app.
        NSApp.setActivationPolicy(.accessory)

        enforceSingleInstance()

        // AppCoordinator owns composition of every standalone controller and
        // must be retained on AppDelegate so its sub-controllers stay alive
        // across the app's lifetime.
        let coord = AppCoordinator()
        coord.bootstrap()
        self.coordinator = coord
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("Shelf terminating")
        coordinator?.teardown()
        // HotkeyManager.deinit unregisters Carbon hotkeys when the
        // coordinator (and through it, the manager) is released.
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // Required by macOS 14+ to avoid warnings; Shelf has no restorable state.
        return true
    }

    private func enforceSingleInstance() {
        let me = Bundle.main.bundleIdentifier ?? "dev.rod.shelf"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: me)
            .filter { $0.processIdentifier != myPID }
        if let existing = others.first {
            log.warning("Another Shelf instance detected (pid=\(existing.processIdentifier, privacy: .public)); activating it and exiting")
            existing.activate()
            NSApp.terminate(self)
        }
    }
}
