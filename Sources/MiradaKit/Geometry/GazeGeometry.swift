import CoreGraphics
import Foundation

/// The reference's gaze-angle math (`estimate_gaze_angle` /
/// `shifting_angles_estimator`), ported exactly except that the angle stays a
/// float instead of being truncated to whole degrees.
///
/// Coordinates are centimetres with the origin at the screen centre, +x to
/// the right, +y down, and −z toward the user. The user is assumed to look at
/// the screen centre; the camera sits at `offset`.
public enum GazeGeometry {
    /// Training range of the FLX data (DIRL): ±30° vertical, ±40° horizontal.
    public static let maxVertical = 30.0
    public static let maxHorizontal = 40.0

    public struct Estimate: Sendable, Equatable {
        /// Redirection that makes the eyes look at the camera, unclamped.
        public var angle: GazeAngle
        /// Estimated eye-midpoint position, cm.
        public var eye: SIMD3<Double>
    }

    /// - Parameters:
    ///   - leftCenter/rightCenter: eye centres in upright pixels.
    ///   - frameSize: upright frame size in pixels.
    public static func estimate(leftCenter le: CGPoint, rightCenter re: CGPoint, frameSize: CGSize, camera c: CameraGeometry) -> Estimate {
        let ipdPixels = max(1e-6, Double(hypot(le.x - re.x, le.y - re.y)))
        let ez = -(c.focalLength * c.ipd) / ipdPixels
        // The reference flips x so that "right" means the user's right.
        let ex = -abs(ez) * (Double(le.x + re.x) - Double(frameSize.width)) / (2 * c.focalLength) + c.offsetX
        let ey = abs(ez) * (Double(le.y + re.y) - Double(frameSize.height)) / (2 * c.focalLength) + c.offsetY

        func deg(_ r: Double) -> Double { r * 180 / .pi }
        // Eye -> screen centre (where the user looks), then eye -> camera.
        let toScreenV = deg(atan((0 - ey) / (0 - ez)))
        let toScreenH = deg(atan((0 - ex) / (0 - ez)))
        let toCameraV = deg(atan((ey - c.offsetY) / (c.offsetZ - ez)))
        let toCameraH = deg(atan((ex - c.offsetX) / (c.offsetZ - ez)))
        return Estimate(angle: GazeAngle(vertical: toScreenV + toCameraV, horizontal: toScreenH + toCameraH), eye: SIMD3(ex, ey, ez))
    }

    /// Clamps to the range the model was trained on.
    public static func clamp(_ a: GazeAngle) -> GazeAngle {
        GazeAngle(vertical: min(max(a.vertical, -maxVertical), maxVertical),
                  horizontal: min(max(a.horizontal, -maxHorizontal), maxHorizontal))
    }
}

extension CameraGeometry {
    /// Default for a Mac whose camera sits centred above a display of the
    /// given physical size (a MacBook's built-in screen): camera about 0.8 cm
    /// above the top edge of the picture, in the screen plane.
    public static func aboveDisplay(widthMM: Double, heightMM: Double) -> CameraGeometry {
        var g = CameraGeometry()
        g.offsetX = 0
        g.offsetY = -(heightMM / 20 + 0.8)
        g.offsetZ = -0.5
        return g
    }
}
