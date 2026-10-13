import Foundation
import os

public enum Stage: String, CaseIterable, Sendable, Codable {
    case capture, landmarks, model, compose, total
}

public struct StageSummary: Sendable, Codable, Equatable {
    public let p50: Double
    public let p95: Double
    public let count: Int
}

/// Rolling per-stage timings in milliseconds. Percentiles use the
/// nearest-rank method over the most recent `capacity` samples.
public final class StageStats: Sendable {
    private struct Ring {
        var values: [Double] = []
        var next = 0
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: [Stage: Ring]())

    public init(capacity: Int = 900) {
        self.capacity = capacity
    }

    public func record(_ stage: Stage, ms: Double) {
        let capacity = capacity
        state.withLock { rings in
            var ring = rings[stage, default: Ring()]
            if ring.values.count < capacity {
                ring.values.append(ms)
            } else {
                ring.values[ring.next] = ms
            }
            ring.next = (ring.next + 1) % capacity
            rings[stage] = ring
        }
    }

    public func summary() -> [Stage: StageSummary] {
        state.withLock { rings in
            rings.compactMapValues { ring in
                guard !ring.values.isEmpty else { return nil }
                let sorted = ring.values.sorted()
                return StageSummary(
                    p50: Self.nearestRank(sorted, 0.50),
                    p95: Self.nearestRank(sorted, 0.95),
                    count: sorted.count
                )
            }
        }
    }

    public func reset() {
        state.withLock { $0.removeAll() }
    }

    static func nearestRank(_ sorted: [Double], _ p: Double) -> Double {
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}

/// Monotonic stopwatch in milliseconds.
public struct Stopwatch: Sendable {
    private let start = ContinuousClock.now
    public init() {}
    public var ms: Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
