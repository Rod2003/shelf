import AppKit
import Foundation
import OSLog
import ShelfCore

@MainActor
public final class ShakeDetector {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "drag")
    private let dragPasteboard: NSPasteboard
    private let pressedMouseButtons: () -> Int
    private var lastDragChangeCount: Int
    private var lowFreqTimer: Timer?
    private var highFreqTimer: Timer?
    private var dragActiveSince: Date?
    private var heuristic: ShakeHeuristic
    private var lastSampleTime: Date?

    public static let idlePollSec: TimeInterval = 0.20
    public static let activePollSec: TimeInterval = 1.0 / 60.0
    public static let dragEndStagnationSec: TimeInterval = 0.6

    // Keep in sync with `DragItemFactory.acceptedPasteboardTypes` without importing Drag into Detect.
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

    var isHighFreqSamplingActive: Bool {
        dragActiveSince != nil
    }

    public init(
        config: ShakeHeuristic.Config = .defaultMedium,
        dragPasteboard: NSPasteboard = NSPasteboard(name: .drag),
        pressedMouseButtons: @escaping @autoclosure () -> Int = NSEvent.pressedMouseButtons
    ) {
        self.dragPasteboard = dragPasteboard
        self.pressedMouseButtons = pressedMouseButtons
        self.lastDragChangeCount = dragPasteboard.changeCount
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
        lastDragChangeCount = dragPasteboard.changeCount
        log.info("ShakeDetector stopped")
    }

    func checkDragStarted() {
        let currentChangeCount = dragPasteboard.changeCount
        defer { lastDragChangeCount = currentChangeCount }

        if dragActiveSince != nil {
            guard isRealFileDragInFlight() else {
                endHighFreqSampling()
                return
            }
            return
        }

        guard currentChangeCount != lastDragChangeCount else { return }
        guard isRealFileDragInFlight() else { return }

        beginHighFreqSampling()
    }

    private func isRealFileDragInFlight() -> Bool {
        guard pressedMouseButtons() != 0 else { return false }
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
        lastDragChangeCount = dragPasteboard.changeCount
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
