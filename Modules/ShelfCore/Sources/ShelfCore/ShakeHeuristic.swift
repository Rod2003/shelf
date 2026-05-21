import Foundation
import CoreGraphics

public struct ShakeHeuristic {
    public struct Config: Equatable, Sendable {
        public var minDeltaPx: Double
        public var minReversals: Int
        public var timeWindowSec: Double
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

        public static let defaultLow = Config(
            minDeltaPx: 8.0,
            minReversals: 6,
            timeWindowSec: 0.5,
            minDurationSec: 0.30
        )

        public static let defaultMedium = Config(
            minDeltaPx: 4.0,
            minReversals: 4,
            timeWindowSec: 0.6,
            minDurationSec: 0.25
        )

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

    public mutating func ingest(timestamp: TimeInterval, position: CGPoint) -> Event {
        window.append(Sample(timestamp: timestamp, x: Double(position.x)))

        while window.count > 1,
              let oldest = window.first,
              timestamp - oldest.timestamp > config.timeWindowSec {
            window.removeFirst()
        }

        guard let first = window.first,
              let last = window.last,
              window.count >= 2 else { return .none }

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
            window.removeAll(keepingCapacity: true)
            return .shake
        }
        return .none
    }

    public mutating func reset() {
        window.removeAll(keepingCapacity: true)
    }
}
