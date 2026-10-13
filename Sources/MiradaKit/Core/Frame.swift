import CoreMedia
import CoreVideo
import ImageIO

/// One video frame. The pixel buffer is IOSurface-backed 32BGRA.
///
/// Ownership rule: nobody mutates a frame's pixels after it is created.
/// Stages that change pixels write into a fresh buffer from a pool. That is
/// what makes the `@unchecked Sendable` safe.
public struct Frame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let time: CMTime
    /// How the stored pixels must be rotated to look upright (file sources
    /// with a rotation transform). Camera frames are `.up`.
    public let orientation: CGImagePropertyOrientation
    /// Focal length in pixels at this frame's size, when the camera reports
    /// its lens (live cameras do; files usually don't).
    public let focalLength: Double?

    public init(pixelBuffer: CVPixelBuffer, time: CMTime, orientation: CGImagePropertyOrientation = .up, focalLength: Double? = nil) {
        self.pixelBuffer = pixelBuffer
        self.time = time
        self.orientation = orientation
        self.focalLength = focalLength
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }

    /// Maps between upright coordinates (what Vision and the gaze math see)
    /// and stored buffer coordinates.
    public var mapping: UprightMapping {
        UprightMapping(bufferWidth: width, bufferHeight: height, orientation: orientation)
    }
}

/// Affine map from upright pixel coordinates to buffer pixel coordinates for
/// the eight EXIF orientations. Coordinates are continuous pixel positions
/// with the origin at the top-left corner of the top-left pixel.
public struct UprightMapping: Sendable, Equatable {
    public let bufferWidth: Int
    public let bufferHeight: Int
    public let orientation: CGImagePropertyOrientation

    public init(bufferWidth: Int, bufferHeight: Int, orientation: CGImagePropertyOrientation) {
        self.bufferWidth = bufferWidth
        self.bufferHeight = bufferHeight
        self.orientation = orientation
    }

    private var swapsAxes: Bool {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: true
        default: false
        }
    }

    public var uprightWidth: Int { swapsAxes ? bufferHeight : bufferWidth }
    public var uprightHeight: Int { swapsAxes ? bufferWidth : bufferHeight }

    /// Row-major 2x3 matrix `[a, b, tx, c, d, ty]` with
    /// `buffer = (a*u + b*v + tx, c*u + d*v + ty)`.
    public var uprightToBuffer: [Float] {
        let w = Float(bufferWidth), h = Float(bufferHeight)
        switch orientation {
        case .up: return [1, 0, 0, 0, 1, 0]
        case .upMirrored: return [-1, 0, w, 0, 1, 0]
        case .down: return [-1, 0, w, 0, -1, h]
        case .downMirrored: return [1, 0, 0, 0, -1, h]
        // Stored image must be rotated 90° CW to be upright (typical portrait phone video).
        case .right: return [0, 1, 0, -1, 0, h]
        case .rightMirrored: return [0, -1, w, -1, 0, h]
        case .left: return [0, -1, w, 1, 0, 0]
        case .leftMirrored: return [0, 1, 0, 1, 0, 0]
        @unknown default: return [1, 0, 0, 0, 1, 0]
        }
    }

    public func bufferPoint(_ p: CGPoint) -> CGPoint {
        let m = uprightToBuffer.map(CGFloat.init)
        return CGPoint(x: m[0] * p.x + m[1] * p.y + m[2], y: m[3] * p.x + m[4] * p.y + m[5])
    }
}
