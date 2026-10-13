import CoreGraphics
import Foundation

/// Decides when correction must fade out: closed eyes, a turned head, or a
/// face too small to correct. Uses hysteresis so the state doesn't chatter.
public struct FaceGate: Sendable {
    /// Eye aspect ratio below which the eyes count as closed, and above which open again.
    public var closeEAR = 0.17
    public var openEAR = 0.21
    /// Head angles (degrees) beyond which the user is looking away.
    public var enterYaw = 25.0
    public var exitYaw = 20.0
    public var enterPitch = 25.0
    public var exitPitch = 20.0
    /// Smallest interocular distance (px) worth correcting.
    public var minInterocular = 24.0

    private var closed = false
    private var away = false

    public init() {}

    public mutating func reset() {
        closed = false
        away = false
    }

    /// Eye aspect ratio (Soukupová & Čech 2016): lid opening over eye width.
    public static func aspectRatio(_ e: EyePoints) -> Double {
        func d(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
        let width = max(1e-6, d(e.outer, e.inner))
        return (d(e.upperOuter, e.lowerOuter) + d(e.upperInner, e.lowerInner)) / (2 * width)
    }

    public mutating func classify(_ face: FaceLandmarks) -> FaceState {
        if face.interocularPixels < minInterocular { return .tooSmall }

        let yaw = abs(face.yaw ?? 0), pitch = abs(face.pitch ?? 0)
        away = away ? (yaw > exitYaw || pitch > exitPitch) : (yaw > enterYaw || pitch > enterPitch)
        if away { return .lookingAway }

        let ear = (Self.aspectRatio(face.leftEye) + Self.aspectRatio(face.rightEye)) / 2
        closed = closed ? ear < openEAR : ear < closeEAR
        return closed ? .blinking : .tracking
    }
}
