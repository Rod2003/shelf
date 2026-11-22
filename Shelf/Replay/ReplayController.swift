import AppKit
import OSLog

/// Owns the replay on/off setting and turns hotkey presses into saved clips.
@MainActor
final class ReplayController: ObservableObject {
    static let enabledKey = "dev.rod.shelf.replayEnabled"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }
    @Published private(set) var status: String?

    var onEnabledChanged: ((Bool) -> Void)?

    private let recorder = ReplayRecorder()
    private let log = Logger(subsystem: "dev.rod.shelf", category: "replay")
    private var isSaving = false

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        recorder.onUserStopped = { [weak self] in
            MainActor.assumeIsolated { self?.isEnabled = false }
        }
    }

    func bootstrap() {
        if isEnabled { start() }
    }

    func teardown() {
        recorder.stop()
    }

    /// Saves the last 30 s to ~/Movies/Shelf Replays and returns the file URL.
    func saveReplay() async -> URL? {
        guard isEnabled, !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            let url = try Self.nextReplayURL()
            try await recorder.save(to: url)
            return url
        } catch {
            log.error("Replay save failed: \(String(describing: error), privacy: .public)")
            status = error.localizedDescription
            NSSound.beep()
            return nil
        }
    }

    private func start() {
        onEnabledChanged?(true)
        status = "Starting…"
        Task {
            do {
                try await recorder.start()
                status = nil
            } catch {
                log.error("Replay start failed: \(String(describing: error), privacy: .public)")
                // Most likely Screen Recording permission was denied.
                status = "Allow Shelf in System Settings → Privacy & Security → Screen & System Audio Recording, then toggle Replay again."
            }
        }
    }

    private func stop() {
        onEnabledChanged?(false)
        recorder.stop()
        status = nil
    }

    private static func nextReplayURL() throws -> URL {
        let fm = FileManager.default
        let movies = fm.urls(for: .moviesDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        let dir = movies.appendingPathComponent("Shelf Replays", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("Replay \(formatter.string(from: Date())).mp4")
    }
}
