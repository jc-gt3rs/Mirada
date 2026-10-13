import Foundation

/// One Euro filter (Casiez, Roussel, Vogel, CHI 2012): a low-pass filter whose
/// cutoff rises with speed, so slow jitter is smoothed hard while real motion
/// passes with little lag.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var x: Double?
    private var dx = 0.0
    private var t: Double?

    public init(minCutoff: Double, beta: Double, dCutoff: Double = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public var value: Double? { x }

    public mutating func reset() {
        x = nil
        t = nil
        dx = 0
    }

    /// Filters `value` sampled at time `time` (seconds). Non-increasing
    /// timestamps are treated as one 30 fps frame apart.
    public mutating func filter(_ value: Double, at time: Double) -> Double {
        guard let prev = x, let prevT = t else {
            x = value
            t = time
            return value
        }
        let dt = time > prevT ? time - prevT : 1.0 / 30
        t = prevT + dt
        let rawDx = (value - prev) / dt
        dx += Self.alpha(dt: dt, cutoff: dCutoff) * (rawDx - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let next = prev + Self.alpha(dt: dt, cutoff: cutoff) * (value - prev)
        x = next
        return next
    }

    static func alpha(dt: Double, cutoff: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// One Euro filters on every eye landmark coordinate. Coordinates are divided
/// by the interocular distance before filtering, so the same parameters work
/// for near and far faces and any resolution.
public struct LandmarkSmoother: Sendable {
    public var minCutoff: Double
    public var beta: Double
    private var filters: [OneEuroFilter] = []
    private var pupilFilters: [OneEuroFilter] = []
    private var scale: Double?

    public init(minCutoff: Double = 1.2, beta: Double = 0.6) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    public mutating func reset() {
        filters.removeAll()
        pupilFilters.removeAll()
        scale = nil
    }

    public mutating func smooth(_ face: FaceLandmarks, at time: Double) -> FaceLandmarks {
        let iod = max(1, face.interocularPixels)
        // The scale itself moves slowly (distance to camera), so a plain EMA is enough.
        let s = scale.map { $0 + 0.1 * (iod - $0) } ?? iod
        scale = s
        let points = face.leftEye.ordered + face.rightEye.ordered
        if filters.count != points.count * 2 {
            filters = Array(repeating: OneEuroFilter(minCutoff: minCutoff, beta: beta), count: points.count * 2)
        }
        var out: [CGPoint] = []
        for (i, p) in points.enumerated() {
            let x = filters[2 * i].filter(Double(p.x) / s, at: time) * s
            let y = filters[2 * i + 1].filter(Double(p.y) / s, at: time) * s
            out.append(CGPoint(x: x, y: y))
        }
        var smoothed = face
        smoothed.leftEye = EyePoints(ordered: Array(out[0..<6]))
        smoothed.rightEye = EyePoints(ordered: Array(out[6..<12]))
        // Pupils get their own filters (they move with gaze, not just the head).
        if let l = face.leftPupil, let r = face.rightPupil {
            if pupilFilters.count != 4 { pupilFilters = Array(repeating: OneEuroFilter(minCutoff: minCutoff, beta: beta), count: 4) }
            smoothed.leftPupil = CGPoint(x: pupilFilters[0].filter(Double(l.x) / s, at: time) * s, y: pupilFilters[1].filter(Double(l.y) / s, at: time) * s)
            smoothed.rightPupil = CGPoint(x: pupilFilters[2].filter(Double(r.x) / s, at: time) * s, y: pupilFilters[3].filter(Double(r.y) / s, at: time) * s)
        } else {
            pupilFilters.removeAll()
        }
        return smoothed
    }
}
