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
    ) -> [Bool] {
        samples.map { timestamp, position in
            heuristic.ingest(timestamp: timestamp, position: position)
        }
    }

    func testNormalDragSingleDirectionDoesNotTriggerShake() {
        var heuristic = ShakeHeuristic()
        let samples: [(TimeInterval, CGPoint)] = (0..<60).map { i in
            let t = Double(i) / 60.0
            return (t, CGPoint(x: Double(i) * 10.0, y: 0))
        }
        XCTAssertFalse(
            feed(&heuristic, samples).contains(true),
            "Single-direction drag must never emit a shake"
        )
    }

    func testDeliberateShakeTriggersShake() {
        var heuristic = ShakeHeuristic()
        let samples = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        )
        XCTAssertTrue(
            feed(&heuristic, samples).contains(true),
            "5 reversals over 400 ms at ±50 px must emit a shake"
        )
    }

    func testBorderlineFastDragDoesNotTrigger() {
        var heuristic = ShakeHeuristic()
        let samples: [(TimeInterval, CGPoint)] = (0..<30).map { i in
            let t = Double(i) * (0.2 / 30.0)
            return (t, CGPoint(x: Double(i) * 6.67, y: 0))
        }
        XCTAssertFalse(
            feed(&heuristic, samples).contains(true),
            "High-velocity single-direction drag must not trigger shake"
        )
    }

    func testPauseThenShakeTriggers() {
        var heuristic = ShakeHeuristic()
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

        XCTAssertFalse(
            feed(&heuristic, slow).contains(true),
            "Slow-drag phase must not emit shake"
        )
        XCTAssertTrue(
            feed(&heuristic, shake).contains(true),
            "Shake gesture after a slow drag must still trigger shake"
        )
    }

    func testResetClearsState() {
        var heuristic = ShakeHeuristic()
        let partial = sinusoidalSamples(
            centerX: 0, amplitudePx: 50,
            reversals: 2, durationSec: 0.2, sampleHz: 60
        )
        _ = feed(&heuristic, partial)
        heuristic.reset()
        let slow: [(TimeInterval, CGPoint)] = (0..<30).map { i in
            let t = 0.5 + Double(i) * (0.6 / 30.0)
            return (t, CGPoint(x: Double(i) * 5.0, y: 0))
        }
        XCTAssertFalse(
            feed(&heuristic, slow).contains(true),
            "After reset(), a single-direction drag must not emit shake"
        )
    }

    func testAfterShakeAutoResetsBeforeNextShake() {
        var heuristic = ShakeHeuristic()
        let first = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        )
        let second = sinusoidalSamples(
            centerX: 500, amplitudePx: 50,
            reversals: 5, durationSec: 0.4, sampleHz: 60
        ).map { (t, p) in (t + 1.0, p) }

        let shakeCount = (feed(&heuristic, first) + feed(&heuristic, second))
            .filter { $0 }
            .count
        XCTAssertGreaterThanOrEqual(
            shakeCount,
            2,
            "Two distinct shake gestures must each emit a shake"
        )
    }

    func testEmptyIngestYieldsFalse() {
        var heuristic = ShakeHeuristic()
        XCTAssertFalse(
            heuristic.ingest(timestamp: 0, position: CGPoint(x: 100, y: 100)),
            "First sample alone must not count as a shake"
        )
    }
}
