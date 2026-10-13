import CoreMedia

/// What the pipeline knows about the face in a frame.
public enum FaceState: String, Sendable, Equatable, Codable {
    case noFace
    case tracking
    case blinking
    case lookingAway
    case tooSmall
}

/// Pipeline output for one frame.
public struct ProcessedFrame: @unchecked Sendable {
    /// Corrected frame (or the original, untouched, when nothing was corrected).
    public let output: Frame
    /// The input frame, for before/after views.
    public let original: Frame
    public let face: FaceState
    /// Correction angle actually applied, after strength and fade.
    public let angle: GazeAngle?
    /// 0…1 fade applied to the correction (blinks, look-aways, toggling).
    public let fade: Double
    public let landmarks: FaceLandmarks?

    public init(output: Frame, original: Frame, face: FaceState, angle: GazeAngle?, fade: Double, landmarks: FaceLandmarks?) {
        self.output = output
        self.original = original
        self.face = face
        self.angle = angle
        self.fade = fade
        self.landmarks = landmarks
    }

    /// A frame that passed through untouched.
    public static func passthrough(_ frame: Frame, face: FaceState = .noFace, landmarks: FaceLandmarks? = nil) -> ProcessedFrame {
        ProcessedFrame(output: frame, original: frame, face: face, angle: nil, fade: 0, landmarks: landmarks)
    }
}

/// Gaze redirection angle in degrees, in the model's order.
public struct GazeAngle: Sendable, Equatable, Codable {
    public var vertical: Double
    public var horizontal: Double

    public init(vertical: Double, horizontal: Double) {
        self.vertical = vertical
        self.horizontal = horizontal
    }

    public static let zero = GazeAngle(vertical: 0, horizontal: 0)

    public func scaled(by s: Double) -> GazeAngle {
        GazeAngle(vertical: vertical * s, horizontal: horizontal * s)
    }
}
