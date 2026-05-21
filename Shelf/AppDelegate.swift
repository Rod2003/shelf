import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")

    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Shelf launching (pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public))")

        // Use `.accessory` so nonactivating panels do not steal app focus.
        NSApp.setActivationPolicy(.accessory)

        enforceSingleInstance()

        let coord = AppCoordinator()
        coord.bootstrap()
        self.coordinator = coord
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("Shelf terminating")
        coordinator?.teardown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    private func enforceSingleInstance() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
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
