import AppKit
import Foundation
import OSLog
import ShelfCore

@MainActor
public final class ShakeDetector {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "drag")
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var lastDragChangeCount: Int = 0
    private var lowFreqTimer: Timer?
    private var highFreqTimer: Timer?
    private var dragActiveSince: Date?
    private var heuristic: ShakeHeuristic
    private var lastSampleTime: Date?

    public static let idlePollSec: TimeInterval = 0.20
    public static let activePollSec: TimeInterval = 1.0 / 60.0
    public static let dragEndStagnationSec: TimeInterval = 0.6

    // Keep in sync with `DragInView.acceptedTypes` without importing Drag into Detect.
    private static let droppableTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        .URL,
        .png,
        .tiff,
        .fileContents,
        NSPasteboard.PasteboardType("public.image"),
        .string
    ]

    public var onShakeDuringDrag: ((CGPoint) -> Void)?

    public init(config: ShakeHeuristic.Config = .defaultMedium) {
        self.heuristic = ShakeHeuristic(config: config)
    }

    public func start() {
        guard lowFreqTimer == nil else { return }
        lastDragChangeCount = dragPasteboard.changeCount
        lowFreqTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idlePollSec,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkDragStarted()
            }
        }
        log.info("ShakeDetector started (5Hz drag poll)")
    }

    public func stop() {
        lowFreqTimer?.invalidate()
        lowFreqTimer = nil
        endHighFreqSampling()
        log.info("ShakeDetector stopped")
    }

    private func checkDragStarted() {
        lastDragChangeCount = dragPasteboard.changeCount

        let isReal = isRealFileDragInFlight()
        if isReal {
            if dragActiveSince == nil {
                beginHighFreqSampling()
            }
        } else if dragActiveSince != nil {
            endHighFreqSampling()
        }
    }

    private func isRealFileDragInFlight() -> Bool {
        guard NSEvent.pressedMouseButtons != 0 else { return false }
        let advertised = dragPasteboard.types ?? []
        return !Set(advertised).isDisjoint(with: Self.droppableTypes)
    }

    private func beginHighFreqSampling() {
        dragActiveSince = Date()
        lastSampleTime = Date()
        heuristic.reset()
        highFreqTimer = Timer.scheduledTimer(
            withTimeInterval: Self.activePollSec,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
        log.info("ShakeDetector ramped up (60Hz cursor poll)")
    }

    private func endHighFreqSampling() {
        highFreqTimer?.invalidate()
        highFreqTimer = nil
        dragActiveSince = nil
        lastSampleTime = nil
        heuristic.reset()
    }

    private func sample() {
        guard dragActiveSince != nil else { return }

        // Re-validate each tick so button-up or pasteboard clear cannot trigger a phantom shake.
        guard isRealFileDragInFlight() else {
            endHighFreqSampling()
            return
        }

        let now = Date().timeIntervalSinceReferenceDate
        let pos = NSEvent.mouseLocation
        lastSampleTime = Date()

        let event = heuristic.ingest(timestamp: now, position: pos)
        if case .shake = event {
            log.info("Shake detected during drag")
            onShakeDuringDrag?(pos)
            endHighFreqSampling()
        }
    }
}
