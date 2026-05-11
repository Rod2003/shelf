// ShelfCore — pure Swift domain module for Shelf macOS app.
// No AppKit/SwiftUI imports allowed in this module.
import Foundation
import CoreGraphics

/// Pure state machine that ingests cursor samples and emits a `.shake` event
/// when the X-axis motion shows enough rapid direction reversals inside a
/// sliding time window.
///
/// Coordinate-system note: the heuristic only looks at X-axis deltas between
/// consecutive samples. It does NOT care about absolute coordinates or the
/// origin convention. Callers may feed `NSEvent.mouseLocation` (bottom-left
/// origin) or `CGEvent` coordinates (top-left origin) interchangeably; only
/// the sign and magnitude of `dx` matter.
///
/// All time values are caller-provided so tests can inject deterministic
/// timestamps. The state machine never reads the current wall clock.
public struct ShakeHeuristic {

    /// Tunable thresholds. Defaults are derived from Spike A's empirical
    /// findings; see `.sisyphus/spike-A-findings.md` for the rationale.
    public struct Config: Equatable, Sendable {
        /// Minimum |Δx| between consecutive samples to count as a leg.
        public var minDeltaPx: Double
        /// Number of sign reversals required inside `timeWindowSec`.
        public var minReversals: Int
        /// Sliding-window length, in seconds.
        public var timeWindowSec: Double
        /// Minimum window duration before the heuristic may fire. Guards
        /// against a single fast flick masquerading as a shake.
        public var minDurationSec: Double

        public init(
            minDeltaPx: Double,
            minReversals: Int,
            timeWindowSec: Double,
            minDurationSec: Double
        ) {
            self.minDeltaPx = minDeltaPx
            self.minReversals = minReversals
            self.timeWindowSec = timeWindowSec
            self.minDurationSec = minDurationSec
        }

        /// Conservative — requires a vigorous shake. Few false positives,
        /// more false negatives.
        public static let defaultLow = Config(
            minDeltaPx: 8.0,
            minReversals: 6,
            timeWindowSec: 0.5,
            minDurationSec: 0.30
        )

        /// Balanced — recommended starting point (locked from Spike A).
        public static let defaultMedium = Config(
            minDeltaPx: 4.0,
            minReversals: 4,
            timeWindowSec: 0.6,
            minDurationSec: 0.25
        )

        /// Permissive — fires on a gentle wiggle. More false positives.
        public static let defaultHigh = Config(
            minDeltaPx: 3.0,
            minReversals: 3,
            timeWindowSec: 0.7,
            minDurationSec: 0.18
        )
    }

    public enum Event: Equatable, Sendable {
        case none
        case shake
    }

    private struct Sample {
        let timestamp: TimeInterval
        let x: Double
    }

    public let config: Config
    private var window: [Sample] = []

    public init(config: Config = .defaultMedium) {
        self.config = config
    }

    /// Feed one cursor sample. Returns `.shake` exactly once per detected
    /// shake; the internal state auto-clears on emit so a continued gesture
    /// must accumulate fresh evidence before the next firing.
    public mutating func ingest(timestamp: TimeInterval, position: CGPoint) -> Event {
        window.append(Sample(timestamp: timestamp, x: Double(position.x)))

        // Trim samples that fall outside the sliding window. `first` is
        // re-read each iteration via guard-let so this loop never relies
        // on a force unwrap — a regression in the outer count guard
        // would otherwise crash on every cursor move.
        while window.count > 1,
              let oldest = window.first,
              timestamp - oldest.timestamp > config.timeWindowSec {
            window.removeFirst()
        }

        // Need at least two samples to compute any delta.
        guard let first = window.first,
              let last = window.last,
              window.count >= 2 else { return .none }

        // Walk the window counting sign reversals among "qualifying" legs
        // (ones whose |Δx| >= minDeltaPx). Sub-threshold deltas are ignored
        // so cursor jitter near the rest position cannot fake a reversal.
        var reversals = 0
        var lastSign = 0
        for i in 1..<window.count {
            let dx = window[i].x - window[i - 1].x
            if abs(dx) < config.minDeltaPx { continue }
            let sign = dx > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign {
                reversals += 1
            }
            lastSign = sign
        }

        let duration = last.timestamp - first.timestamp
        if reversals >= config.minReversals,
           duration >= config.minDurationSec {
            // Auto-reset so the same wave of motion cannot re-emit on the
            // next ingest; downstream must observe a fresh accumulation.
            window.removeAll(keepingCapacity: true)
            return .shake
        }
        return .none
    }

    /// Discard any pending samples. Call from outside (e.g. when the drag
    /// ends) so the next gesture starts from a clean slate.
    public mutating func reset() {
        window.removeAll(keepingCapacity: true)
    }
}
