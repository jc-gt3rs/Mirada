import CoreGraphics
import Foundation

/// Where the eye is looking within its socket, from the pupil's position
/// between the eye corners.
public enum IrisOffset {
    /// Pupil offset from the corner midpoint as a fraction of the eye's width:
    /// `u` along the eye axis (+ toward the image's right), `v` across it
    /// (+ toward the image's bottom).
    public static func of(_ eye: EyePoints, pupil: CGPoint) -> (u: Double, v: Double) {
        let a = eye.outer.x < eye.inner.x ? eye.outer : eye.inner   // image-left corner
        let b = eye.outer.x < eye.inner.x ? eye.inner : eye.outer
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let width = max(1e-6, (dx * dx + dy * dy).squareRoot())
        let ax = dx / width, ay = dy / width
        let mx = Double(a.x + b.x) / 2, my = Double(a.y + b.y) / 2
        let px = Double(pupil.x) - mx, py = Double(pupil.y) - my
        return ((px * ax + py * ay) / width, (-px * ay + py * ax) / width)
    }
}

/// Your eyes' reading while looking at the middle of the screen: average
/// pupil offset (fractions of eye width, see `IrisOffset`) and head yaw.
public struct GazeCentre: Codable, Sendable, Equatable {
    public var u: Double
    public var v: Double
    public var yaw: Double

    public init(u: Double, v: Double, yaw: Double) {
        self.u = u
        self.v = v
        self.yaw = yaw
    }
}

/// Estimates where you are looking relative to the middle of your screen, so
/// the correction starts from your actual gaze.
///
/// Gaze = head yaw + eye-in-head angle, the eye angle being gain × the pupil's
/// offset between the eye corners (radians, capped at ±45°; an arcsine eyeball
/// model blows up near the corners). The "middle" is your calibration
/// (`fixedCentre`, from "I'm looking at the middle") or, until you calibrate,
/// the running median of the last `window` seconds. Head pitch is left out:
/// Vision's pitch jumps by ±6° frame to frame.
///
/// Angles use the model's convention: + horizontal moves the iris toward the
/// image's right, + vertical moves it up.
public struct GazeTracker: Sendable {
    public var window: Double = 90
    /// Radians of eye rotation per unit of pupil offset (settings gazeGainH/V).
    public var gainH: Double = 2.5
    public var gainV: Double = 2.5
    /// Calibrated middle; nil means learn it from the running median.
    public var fixedCentre: GazeCentre?

    private var fu = OneEuroFilter(minCutoff: 0.8, beta: 0.3)
    private var fv = OneEuroFilter(minCutoff: 0.8, beta: 0.3)
    private var fyaw = OneEuroFilter(minCutoff: 0.6, beta: 0.05)
    private var samples: [(t: Double, c: GazeCentre)] = []
    private var autoCentre: GazeCentre?
    private var sinceMedian = 0
    private(set) var last: GazeCentre?

    public init() {}

    public mutating func reset() {
        samples.removeAll()
        autoCentre = nil
        sinceMedian = 0
        last = nil
        fu.reset()
        fv.reset()
        fyaw.reset()
    }

    /// Averaged pupil offset of both eyes (each eye's mirror-image bias cancels).
    static func offset(_ face: FaceLandmarks) -> (u: Double, v: Double)? {
        guard let lp = face.leftPupil, let rp = face.rightPupil else { return nil }
        let l = IrisOffset.of(face.leftEye, pupil: lp), r = IrisOffset.of(face.rightEye, pupil: rp)
        return ((l.u + r.u) / 2, (l.v + r.v) / 2)
    }

    /// Readings beyond this are Vision losing the pupil (lid, lash, glare).
    static let maxU = 0.35, maxV = 0.3

    /// How far the gaze is from the middle of the screen, or nil without pupils.
    public mutating func deviation(_ face: FaceLandmarks, at t: Double) -> GazeAngle? {
        if let o = Self.offset(face), abs(o.u) < Self.maxU, abs(o.v) < Self.maxV {
            let reading = GazeCentre(u: fu.filter(o.u, at: t), v: fv.filter(o.v, at: t),
                                     yaw: face.yaw.map { fyaw.filter($0, at: t) } ?? 0)
            last = reading
            samples.append((t, reading))
            samples.removeAll { $0.t < t - window }
            sinceMedian += 1
            if autoCentre == nil || sinceMedian >= 15 || samples.count < 30 {
                autoCentre = Self.median(samples.map(\.c))
                sinceMedian = 0
            }
        }
        guard let now = last, let centre = fixedCentre ?? autoCentre else { return nil }
        return Self.angle(now, from: centre, gainH: gainH, gainV: gainV)
    }

    static func angle(_ now: GazeCentre, from c: GazeCentre, gainH: Double, gainV: Double) -> GazeAngle {
        func deg(_ x: Double, _ g: Double) -> Double { max(-45, min(45, g * x * 180 / .pi)) }
        let dh = (now.yaw - c.yaw) + deg(now.u - c.u, gainH)
        // With the iris in a corner, the eye's almond shape moves the pupil
        // up or down against the corner line, and the large vertical gain
        // turns that into fake vertical gaze. Trust vertical fully within 10°
        // sideways, not at all beyond 30°.
        let trust = max(0, min(1, 1 - (abs(dh) - 10) / 20))
        return GazeAngle(vertical: -deg(now.v - c.v, gainV) * trust, horizontal: dh)
    }

    static func median(_ cs: [GazeCentre]) -> GazeCentre? {
        guard !cs.isEmpty else { return nil }
        func m(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
        return GazeCentre(u: m(cs.map(\.u)), v: m(cs.map(\.v)), yaw: m(cs.map(\.yaw)))
    }

    /// "I'm looking at the middle now": the median of the last half second.
    public func captureCentre(now t: Double) -> GazeCentre? {
        Self.median(samples.filter { $0.t >= t - 0.5 }.map(\.c)) ?? last
    }

    /// The current reading's pupil offset from the middle (before gains).
    public var offsetFromCentre: (u: Double, v: Double)? {
        guard let now = last, let c = fixedCentre ?? autoCentre else { return nil }
        return (now.u - c.u, now.v - c.v)
    }

    /// Drop the learned middle (the next frames learn it again).
    public mutating func recenter() {
        samples.removeAll()
        autoCentre = nil
    }
}
