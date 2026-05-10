// Shelf — drag-aware cursor shake detector.
//
// Spike A (see .sisyphus/spike-A-findings.md) locked the no-TCC mechanism:
//   • NSPasteboard(name: .drag).changeCount polled at 5 Hz as a wake-up
//     signal. ~0.27% idle CPU.
//   • While a drag is active, NSEvent.mouseLocation is read at ~60 Hz and
//     fed into ShelfCore.ShakeHeuristic. Both APIs are property reads and
//     do not require Accessibility / Input Monitoring entitlements.
//
// Spike A caveat 3 flagged that bare changeCount ticks fire for ANY process
// writing the system .drag pasteboard, including clipboard syncs and
// services that touch the pasteboard speculatively — leading to spurious
// shake-spawned shelves when the user wiggles the cursor without an actual
// drag. We now gate arming/sampling on `isRealFileDragInFlight()`:
// pressedMouseButtons must be non-zero AND the drag pasteboard must
// advertise types Shelf would actually accept. Both signals are TCC-free
// per-process property reads.
//
// This class is standalone: it owns the timers and the heuristic, and emits
// a single callback when a shake is recognised mid-drag. T18 will compose it
// with ShelfWindowManager via AppDelegate; this file MUST NOT touch other
// modules.
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

    /// 5 Hz drag-pasteboard poll (Spike A: idle CPU ~0.27%).
    public static let idlePollSec: TimeInterval = 0.20
    /// ~60 Hz cursor poll while a drag is active.
    public static let activePollSec: TimeInterval = 1.0 / 60.0
    /// Drag considered ended if changeCount stagnates this long AND cursor
    /// stops moving. Retained as a fallback alongside the new
    /// `isRealFileDragInFlight()` gate.
    public static let dragEndStagnationSec: TimeInterval = 0.6

    /// Pasteboard types that count as a "real" drag worth waking the
    /// heuristic for. Mirrors `DragInView.acceptedTypes` so the predicate
    /// "shake should fire here" matches "Shelf could receive this drop."
    /// Kept private and duplicated rather than depended on the App layer
    /// because Detect/ MUST NOT depend on Drag/ per the original module
    /// boundary in this file's header.
    private static let droppableTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        .URL,
        .png,
        .tiff,
        .fileContents,
        NSPasteboard.PasteboardType("public.image"),
        .string
    ]

    /// Fired exactly once per detected shake. The supplied point is in
    /// `NSEvent.mouseLocation` coordinates (bottom-left origin, screen space).
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
        // Keep the changeCount in sync so a subsequent real drag isn't
        // discarded as "already seen", but the bare counter is no longer
        // the truth source.
        lastDragChangeCount = dragPasteboard.changeCount

        let isReal = isRealFileDragInFlight()
        if isReal {
            if dragActiveSince == nil {
                beginHighFreqSampling()
            }
        } else if dragActiveSince != nil {
            // Button released or pasteboard cleared → tear down regardless
            // of stagnation timer. The sampler self-disarms here as well
            // (defense in depth), but doing it on the 5 Hz tick guarantees
            // we don't keep spinning the 60 Hz timer for free.
            endHighFreqSampling()
        }
    }

    /// True iff a content-bearing drag is in flight RIGHT NOW. Both signals
    /// are TCC-free per-process property reads (Spike A confirmed):
    ///  - `NSEvent.pressedMouseButtons` filters out pure cursor motion
    ///    (no button held → no possible drag session).
    ///  - `dragPasteboard.types` intersected with `droppableTypes` filters
    ///    out window-resize, text-field marquee, and other button-held
    ///    motions that don't publish anything Shelf would accept.
    /// Together: only fires for drags that could land on a shelf cell.
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
        // Only run while a drag is in flight. Defensive: if the timer fires
        // after teardown for any reason, do nothing.
        guard dragActiveSince != nil else { return }

        // Re-validate the drag predicate every tick. A button-up or
        // pasteboard clear mid-motion must stop the heuristic immediately,
        // otherwise the post-release cursor settle could trip a phantom
        // shake before the 5 Hz tick catches up.
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
            // Heuristic auto-resets on emit; tear down high-freq sampling
            // so a subsequent shake within the same drag must accumulate
            // fresh evidence (and another pasteboard changeCount tick).
            endHighFreqSampling()
        }
    }
}
