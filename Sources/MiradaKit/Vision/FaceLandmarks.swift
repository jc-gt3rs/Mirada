import CoreGraphics

/// Six eye points in the order the FLX model was trained on, in upright
/// pixel coordinates (origin top-left).
public struct EyePoints: Sendable, Equatable {
    public var outer: CGPoint
    public var upperOuter: CGPoint
    public var upperInner: CGPoint
    public var inner: CGPoint
    public var lowerInner: CGPoint
    public var lowerOuter: CGPoint

    public init(outer: CGPoint, upperOuter: CGPoint, upperInner: CGPoint, inner: CGPoint, lowerInner: CGPoint, lowerOuter: CGPoint) {
        self.outer = outer
        self.upperOuter = upperOuter
        self.upperInner = upperInner
        self.inner = inner
        self.lowerInner = lowerInner
        self.lowerOuter = lowerOuter
    }

    /// Training order: outer, upper-outer, upper-inner, inner, lower-inner, lower-outer.
    public var ordered: [CGPoint] { [outer, upperOuter, upperInner, inner, lowerInner, lowerOuter] }

    public init(ordered p: [CGPoint]) {
        precondition(p.count == 6)
        self.init(outer: p[0], upperOuter: p[1], upperInner: p[2], inner: p[3], lowerInner: p[4], lowerOuter: p[5])
    }

    /// Midpoint of the two corners. This is what the reference calls the eye center.
    public var center: CGPoint {
        CGPoint(x: (outer.x + inner.x) / 2, y: (outer.y + inner.y) / 2)
    }

    public func map(_ f: (CGPoint) -> CGPoint) -> EyePoints {
        EyePoints(ordered: ordered.map(f))
    }
}

/// Landmarks for one face, upright pixel coordinates.
public struct FaceLandmarks: Sendable, Equatable {
    /// Subject's left eye: on the image's right in an unmirrored frame. Uses the "L" model.
    public var leftEye: EyePoints
    /// Subject's right eye: on the image's left. Uses the "R" model.
    public var rightEye: EyePoints
    public var bounds: CGRect
    /// Head yaw and pitch in degrees, when Vision reports them.
    public var yaw: Double?
    public var pitch: Double?
    /// Pupil centres (subject's left and right), when Vision reports them.
    public var leftPupil: CGPoint?
    public var rightPupil: CGPoint?

    public init(leftEye: EyePoints, rightEye: EyePoints, bounds: CGRect, yaw: Double? = nil, pitch: Double? = nil,
                leftPupil: CGPoint? = nil, rightPupil: CGPoint? = nil) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.bounds = bounds
        self.yaw = yaw
        self.pitch = pitch
        self.leftPupil = leftPupil
        self.rightPupil = rightPupil
    }

    /// Distance between the two eye centers, in pixels.
    public var interocularPixels: Double {
        let a = leftEye.center, b = rightEye.center
        return Double(hypot(a.x - b.x, a.y - b.y))
    }
}
