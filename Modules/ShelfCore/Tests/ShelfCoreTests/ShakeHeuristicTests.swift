import XCTest
import CoreGraphics
@testable import ShelfCore

final class ShakeHeuristicTests: XCTestCase {
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

    func testNormalDragSingleDirectionDoesNotTriggerShake() {
        var h = ShakeHeuristic(config: .defaultMedium)
        let samples: [(TimeInterval, CGPoint)] = (0..<60).map { i in
            let t = Double(i) / 60.0
            return (t, CGPoint(x: Double(i) * 10.0, y: 0))
        }
        let events = feed(&h, samples)
        XCTAssertTrue(events.allSatisfy { $0 == .none },
                      "Single-direction drag must never emit .shake")
    }

    func testDeliberateShakeTriggersShake() {
        var h = ShakeHeuristic(config: .defaultMedium)
        let samples = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        )
        let events = feed(&h, samples)
        XCTAssertTrue(events.contains(.shake),
                      "5 reversals over 400 ms at ±50 px must emit .shake")
    }

    func testBorderlineFastDragDoesNotTrigger() {
        var h = ShakeHeuristic(config: .defaultMedium)
        let samples: [(TimeInterval, CGPoint)] = (0..<30).map { i in
            let t = Double(i) * (0.2 / 30.0)
            return (t, CGPoint(x: Double(i) * 6.67, y: 0))
        }
        let events = feed(&h, samples)
        XCTAssertTrue(events.allSatisfy { $0 == .none },
                      "High-velocity single-direction drag must not trigger shake")
    }

    func testPauseThenShakeTriggers() {
        var h = ShakeHeuristic(config: .defaultMedium)
        let slow: [(TimeInterval, CGPoint)] = (0..<30).map { i in
            let t = Double(i) * (0.8 / 30.0)
            return (t, CGPoint(x: Double(i) * 5.0, y: 0))
        }
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

    func testResetClearsState() {
        var h = ShakeHeuristic(config: .defaultMedium)
        let partial = sinusoidalSamples(
            centerX: 0, amplitudePx: 50,
            reversals: 2, durationSec: 0.2, sampleHz: 60
        )
        _ = feed(&h, partial)
        h.reset()
        let slow: [(TimeInterval, CGPoint)] = (0..<30).map { i in
            let t = 0.5 + Double(i) * (0.6 / 30.0)
            return (t, CGPoint(x: Double(i) * 5.0, y: 0))
        }
        let events = feed(&h, slow)
        XCTAssertTrue(events.allSatisfy { $0 == .none },
                      "After reset(), a single-direction drag must not emit shake")
    }

    func testLowSensitivityRejectsBorderline() {
        let samples = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 4, durationSec: 0.5, sampleHz: 60
        )
        var medium = ShakeHeuristic(config: .defaultMedium)
        XCTAssertTrue(feed(&medium, samples).contains(.shake),
                      "Sanity: medium must accept 4-reversal borderline input")
        var low = ShakeHeuristic(config: .defaultLow)
        XCTAssertFalse(feed(&low, samples).contains(.shake),
                       "Low sensitivity must reject 4-reversal borderline input")
    }

    func testHighSensitivityAcceptsBorderline() {
        let samples = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 4, durationSec: 0.5, sampleHz: 60
        )
        var high = ShakeHeuristic(config: .defaultHigh)
        XCTAssertTrue(feed(&high, samples).contains(.shake),
                      "High sensitivity must accept 4-reversal borderline input")
    }

    func testAfterShakeAutoResetsBeforeNextShake() {
        var h = ShakeHeuristic(config: .defaultMedium)
        let first = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        )
        let second = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        ).map { (t, p) in (t + 1.0, p) }

        let events = feed(&h, first) + feed(&h, second)
        let shakeCount = events.filter { $0 == .shake }.count
        XCTAssertGreaterThanOrEqual(shakeCount, 2,
                                    "Two distinct shake gestures must each emit a shake")
    }

    func testEmptyIngestYieldsNoneEvent() {
        var h = ShakeHeuristic(config: .defaultMedium)
        let event = h.ingest(timestamp: 0, position: CGPoint(x: 100, y: 100))
        XCTAssertEqual(event, .none,
                       "First sample alone must produce .none (no prior delta to compare)")
    }
}
