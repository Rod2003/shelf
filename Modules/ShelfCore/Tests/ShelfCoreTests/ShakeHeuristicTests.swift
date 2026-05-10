import XCTest
import CoreGraphics
@testable import ShelfCore

final class ShakeHeuristicTests: XCTestCase {

    // MARK: - Helpers

    /// Generates samples on a sine wave with `reversals` direction changes
    /// over `durationSec` seconds at `sampleHz`. `centerX` is the rest position;
    /// `amplitudePx` is the peak deviation in either direction.
    ///
    /// Math: x(t) = centerX + amplitudePx * sin(ω * t) where ω = N·π / T.
    /// With this ω the derivative cos(ω·t) has zeros at t = (π/2)/ω,
    /// (3π/2)/ω, ... giving exactly `reversals` direction changes in [0, T].
    func sinusoidalSamples(
        centerX: Double,
        amplitudePx: Double,
        reversals: Int,
        durationSec: Double,
        sampleHz: Double
    ) -> [(TimeInterval, CGPoint)] {
        let omega = Double(reversals) * .pi / durationSec
        let n = max(2, Int((durationSec * sampleHz).rounded()))
        var out: [(TimeInterval, CGPoint)] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) / sampleHz
            let x = centerX + amplitudePx * sin(omega * t)
            out.append((t, CGPoint(x: x, y: 0)))
        }
        return out
    }

    /// Feeds samples into a heuristic and returns the per-ingest event stream.
    func feed(
        _ heuristic: inout ShakeHeuristic,
        _ samples: [(TimeInterval, CGPoint)]
    ) -> [ShakeHeuristic.Event] {
        var events: [ShakeHeuristic.Event] = []
        events.reserveCapacity(samples.count)
        for (ts, pos) in samples {
            events.append(heuristic.ingest(timestamp: ts, position: pos))
        }
        return events
    }

    // MARK: - 1. Normal drag does not trigger

    func testNormalDragSingleDirectionDoesNotTriggerShake() {
        var h = ShakeHeuristic(config: .defaultMedium)
        // 60 samples over 1.0s, moving right at constant velocity (~10 px / sample).
        let samples: [(TimeInterval, CGPoint)] = (0..<60).map { i in
            let t = Double(i) / 60.0
            return (t, CGPoint(x: Double(i) * 10.0, y: 0))
        }
        let events = feed(&h, samples)
        XCTAssertTrue(events.allSatisfy { $0 == .none },
                      "Single-direction drag must never emit .shake")
    }

    // MARK: - 2. Deliberate shake triggers

    func testDeliberateShakeTriggersShake() {
        var h = ShakeHeuristic(config: .defaultMedium)
        // 5 reversals over 400 ms at ±50 px amplitude — a deliberate shake.
        let samples = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        )
        let events = feed(&h, samples)
        XCTAssertTrue(events.contains(.shake),
                      "5 reversals over 400 ms at ±50 px must emit .shake")
    }

    // MARK: - 3. Borderline fast single-direction drag does not trigger

    func testBorderlineFastDragDoesNotTrigger() {
        var h = ShakeHeuristic(config: .defaultMedium)
        // 30 samples over 200 ms, single direction at high velocity.
        // ~6.67 px / sample => ~1000 px/s — well above any per-sample threshold,
        // but contains zero direction changes and is too short for the duration gate.
        let samples: [(TimeInterval, CGPoint)] = (0..<30).map { i in
            let t = Double(i) * (0.2 / 30.0)
            return (t, CGPoint(x: Double(i) * 6.67, y: 0))
        }
        let events = feed(&h, samples)
        XCTAssertTrue(events.allSatisfy { $0 == .none },
                      "High-velocity single-direction drag must not trigger shake")
    }

    // MARK: - 4. Pause then shake triggers shake on the shake portion

    func testPauseThenShakeTriggers() {
        var h = ShakeHeuristic(config: .defaultMedium)
        // 800 ms slow rightward drag (no reversals).
        let slow: [(TimeInterval, CGPoint)] = (0..<30).map { i in
            let t = Double(i) * (0.8 / 30.0)
            return (t, CGPoint(x: Double(i) * 5.0, y: 0))
        }
        // 400 ms shake immediately after, centered at last slow position.
        let lastSlowX = 29.0 * 5.0
        let shakeRaw = sinusoidalSamples(
            centerX: lastSlowX, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        )
        let shake = shakeRaw.map { (t, p) in (t + 0.8, p) }

        let slowEvents = feed(&h, slow)
        XCTAssertTrue(slowEvents.allSatisfy { $0 == .none },
                      "Slow-drag phase must not emit shake")

        let shakeEvents = feed(&h, shake)
        XCTAssertTrue(shakeEvents.contains(.shake),
                      "Shake gesture after a slow drag must still trigger shake")
    }

    // MARK: - 5. reset() clears state

    func testResetClearsState() {
        var h = ShakeHeuristic(config: .defaultMedium)
        // Feed enough to start accumulating reversals but NOT enough to fire.
        let partial = sinusoidalSamples(
            centerX: 0, amplitudePx: 50,
            reversals: 2, durationSec: 0.2, sampleHz: 60
        )
        _ = feed(&h, partial)
        h.reset()
        // After reset, a single-direction drag must not emit shake.
        let slow: [(TimeInterval, CGPoint)] = (0..<30).map { i in
            let t = 0.5 + Double(i) * (0.6 / 30.0)
            return (t, CGPoint(x: Double(i) * 5.0, y: 0))
        }
        let events = feed(&h, slow)
        XCTAssertTrue(events.allSatisfy { $0 == .none },
                      "After reset(), a single-direction drag must not emit shake")
    }

    // MARK: - 6. Low sensitivity rejects borderline input that medium accepts

    func testLowSensitivityRejectsBorderline() {
        // 4 reversals over 500 ms — exactly at default-medium's threshold.
        let samples = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 4, durationSec: 0.5, sampleHz: 60
        )
        // Sanity: medium accepts.
        var medium = ShakeHeuristic(config: .defaultMedium)
        XCTAssertTrue(feed(&medium, samples).contains(.shake),
                      "Sanity: medium must accept 4-reversal borderline input")
        // Low (requires 6 reversals) must reject.
        var low = ShakeHeuristic(config: .defaultLow)
        XCTAssertFalse(feed(&low, samples).contains(.shake),
                       "Low sensitivity must reject 4-reversal borderline input")
    }

    // MARK: - 7. High sensitivity accepts borderline input

    func testHighSensitivityAcceptsBorderline() {
        let samples = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 4, durationSec: 0.5, sampleHz: 60
        )
        var high = ShakeHeuristic(config: .defaultHigh)
        XCTAssertTrue(feed(&high, samples).contains(.shake),
                      "High sensitivity must accept 4-reversal borderline input")
    }

    // MARK: - 8. After shake auto-resets before the next shake

    func testAfterShakeAutoResetsBeforeNextShake() {
        var h = ShakeHeuristic(config: .defaultMedium)
        let first = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        )
        // Second shake offset by 1.0 s so the window from the first cannot
        // bleed into the second.
        let second = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        ).map { (t, p) in (t + 1.0, p) }

        let events = feed(&h, first) + feed(&h, second)
        let shakeCount = events.filter { $0 == .shake }.count
        XCTAssertGreaterThanOrEqual(shakeCount, 2,
                                    "Two distinct shake gestures must each emit a shake")
    }

    // MARK: - 9. First sample alone yields .none

    func testEmptyIngestYieldsNoneEvent() {
        var h = ShakeHeuristic(config: .defaultMedium)
        let event = h.ingest(timestamp: 0, position: CGPoint(x: 100, y: 100))
        XCTAssertEqual(event, .none,
                       "First sample alone must produce .none (no prior delta to compare)")
    }
}
