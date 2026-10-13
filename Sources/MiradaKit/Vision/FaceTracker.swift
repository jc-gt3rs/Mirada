import CoreGraphics
import CoreML
import CoreVideo
import os
import Vision

/// Finds the largest face and its eye landmarks with Apple Vision.
///
/// Uses face rectangles revision 3 (continuous yaw/pitch/roll) followed by
/// landmarks on the same observations (76-point constellation, which gives
/// six points per eye in the order the FLX model was trained on).
///
/// Face detection is the expensive half, so it runs every
/// `redetectInterval` frames. In between, the last face box is moved with the
/// eyes and only landmarks run; a low landmark confidence forces a fresh
/// detection.
public final class FaceTracker: @unchecked Sendable {
    private let rectangles: VNDetectFaceRectanglesRequest
    private let landmarks: VNDetectFaceLandmarksRequest
    /// Normalized bounds of the face followed last frame.
    private var followed: CGRect?
    /// Another face must be this much larger to take over, so two similar
    /// faces don't make the correction flip between people.
    static let switchRatio: CGFloat = 1.3

    public var redetectInterval: Int
    private var tracked: VNFaceObservation?
    /// Eye centroid (normalized, Vision coordinates) when `tracked` was made.
    private var trackedAnchor: CGPoint?
    private var lastAnchor: CGPoint?
    private var sinceDetect = 0
    /// How the last frame's face was found: `detect` (full search), `track`
    /// (box carried from earlier frames), `refresh` (tracked, with a new
    /// search started in the background), or `idle` (nobody, throttled).
    public private(set) var lastMode = "idle"

    /// Frames where a full detection ran (for measurements).
    public private(set) var detections = 0
    /// Cumulative time in each Vision request (for measurements).
    public private(set) var rectanglesMs = 0.0
    public private(set) var landmarksMs = 0.0
    public private(set) var landmarkRuns = 0
    /// With nobody in view, look only every few frames (saves power; costs at
    /// most this many frames of delay when someone sits down).
    public var idleInterval = 3
    private var idleSkipped = 0

    public init(redetectInterval: Int = 6) {
        self.redetectInterval = max(1, redetectInterval)
        rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        landmarks = VNDetectFaceLandmarksRequest()
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
        landmarks.constellation = .constellation76Points
        if let want = ProcessInfo.processInfo.environment["MIRADA_VISION_DEVICE"] {
            Self.pin([rectangles, landmarks], to: want)
        }
    }

    /// Pins every compute stage of the requests to `cpu`, `gpu` or `ane`, where supported.
    static func pin(_ requests: [VNRequest], to want: String) {
        for request in requests {
            guard let stages = try? request.supportedComputeStageDevices else { continue }
            for (stage, devices) in stages {
                let match = devices.first { d in
                    switch d {
                    case .cpu: want == "cpu"
                    case .gpu: want == "gpu"
                    case .neuralEngine: want == "ane"
                    @unknown default: false
                    }
                }
                if let match { request.setComputeDevice(match, for: stage) }
            }
        }
    }

    /// Landmarks of the largest face, in upright pixel coordinates, or nil.
    public func detect(_ frame: Frame) throws -> FaceLandmarks? {
        let handler = VNImageRequestHandler(cvPixelBuffer: Self.untagged(frame.pixelBuffer), orientation: frame.orientation, options: [:])
        adoptBackgroundDetection()
        // Tracking pass. Any failure (low confidence, Vision refusing the box)
        // falls through to a fresh detection instead of failing the frame:
        // reusing a bad box would fail every frame after it.
        if tracked != nil, let carried = carriedObservation(),
           let result = try? landmarks(handler, carried, frame), result.confidence >= 0.5 {
            sinceDetect += 1
            lastMode = "track"
            // Refresh the face box off the frame's critical path.
            if sinceDetect >= redetectInterval {
                startBackgroundDetection(frame)
                lastMode = "refresh"
            }
            return result.face
        }
        // Full detection (throttled while nobody is in view).
        if tracked == nil, idleSkipped < idleInterval - 1, detections > 0 {
            idleSkipped += 1
            lastMode = "idle"
            return nil
        }
        lastMode = "detect"
        idleSkipped = 0
        sinceDetect = 0
        detections += 1
        let rsw = Stopwatch()
        try handler.perform([rectangles])
        rectanglesMs += rsw.ms
        guard let chosen = choose(rectangles.results ?? []) else {
            clearTracking()
            return nil
        }
        followed = chosen.boundingBox
        tracked = chosen
        trackedAnchor = nil
        guard let result = try? landmarks(handler, chosen, frame) else { return nil }
        return result.face
    }

    // MARK: background re-detection

    private let detectQueue = DispatchQueue(label: "mirada.vision.detect", qos: .userInitiated)
    private let backgroundRectangles: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()
    /// (in flight, finished result) shared with the detect queue.
    private let background = OSAllocatedUnfairLock<(running: Bool, faces: [VNFaceObservation]?)>(uncheckedState: (false, nil))

    private struct FrameRef: @unchecked Sendable { let frame: Frame }

    private func startBackgroundDetection(_ frame: Frame) {
        let shouldStart = background.withLockUnchecked { state -> Bool in
            if state.running { return false }
            state.running = true
            return true
        }
        guard shouldStart else { return }
        sinceDetect = 0
        let ref = FrameRef(frame: frame)
        detectQueue.async { [self] in
            let handler = VNImageRequestHandler(cvPixelBuffer: Self.untagged(ref.frame.pixelBuffer), orientation: ref.frame.orientation, options: [:])
            let sw = Stopwatch()
            let faces = (try? handler.perform([backgroundRectangles])).flatMap { backgroundRectangles.results } ?? []
            let ms = sw.ms
            background.withLockUnchecked { state in
                state.running = false
                state.faces = faces
            }
            backgroundMs.withLock { $0 += ms }
        }
    }

    private let backgroundMs = OSAllocatedUnfairLock(initialState: 0.0)

    /// Takes a finished background detection as the new face box.
    private func adoptBackgroundDetection() {
        guard let faces = background.withLockUnchecked({ state -> [VNFaceObservation]? in
            defer { state.faces = nil }
            return state.faces
        }) else { return }
        detections += 1
        rectanglesMs = backgroundMs.withLock { $0 }
        guard tracked != nil, let chosen = choose(faces) else { return }
        followed = chosen.boundingBox
        tracked = chosen
        trackedAnchor = nil
    }

    /// The last detected face box, moved by how far the eyes have moved since.
    private func carriedObservation() -> VNFaceObservation? {
        guard let tracked else { return nil }
        // A fresh box (just detected) is used as-is; it then follows the eyes.
        let moved: CGRect
        if let a = trackedAnchor, let b = lastAnchor {
            moved = tracked.boundingBox.offsetBy(dx: b.x - a.x, dy: b.y - a.y)
        } else {
            moved = tracked.boundingBox
        }
        // Keep the box inside the image: Vision rejects boxes outside it
        // ("Cropping failed. Specified ROI is outside of input image bounds").
        let box = moved.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0.04, box.height > 0.04 else { return nil }
        if box == tracked.boundingBox { return tracked }
        return VNFaceObservation(requestRevision: VNDetectFaceRectanglesRequestRevision3, boundingBox: box,
                                 roll: tracked.roll, yaw: tracked.yaw, pitch: tracked.pitch)
    }

    private func landmarks(_ handler: VNImageRequestHandler, _ observation: VNFaceObservation, _ frame: Frame) throws
        -> (face: FaceLandmarks, confidence: Float)? {
        landmarks.inputFaceObservations = [observation]
        let lsw = Stopwatch()
        try handler.perform([landmarks])
        landmarksMs += lsw.ms
        landmarkRuns += 1
        guard let face = landmarks.results?.first, let marks = face.landmarks,
              let visionLeft = marks.leftEye, let visionRight = marks.rightEye
        else { return nil }

        // Remember where the eyes are, in normalized Vision coordinates, so the
        // box can follow them until the next detection.
        let eyes = (visionLeft.normalizedPoints + visionRight.normalizedPoints).map {
            CGPoint(x: face.boundingBox.minX + $0.x * face.boundingBox.width, y: face.boundingBox.minY + $0.y * face.boundingBox.height)
        }
        let anchor = centroid(eyes)
        if trackedAnchor == nil { trackedAnchor = anchor }
        lastAnchor = anchor

        let map = frame.mapping
        let size = CGSize(width: map.uprightWidth, height: map.uprightHeight)
        func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
            region.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) }
        }
        // Vision's `leftEye` is the one on the image's left: the subject's right eye.
        let imageLeft = points(visionLeft), imageRight = points(visionRight)
        guard let subjectRight = EyePoints.fromContour(imageLeft, otherEyeCenter: centroid(imageRight)),
              let subjectLeft = EyePoints.fromContour(imageRight, otherEyeCenter: centroid(imageLeft))
        else { return nil }

        let box = face.boundingBox
        let bounds = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
        let landmarks = FaceLandmarks(
            leftEye: subjectLeft,
            rightEye: subjectRight,
            bounds: bounds,
            yaw: (observation.yaw?.doubleValue).map { $0 * 180 / .pi },
            pitch: (observation.pitch?.doubleValue).map { $0 * 180 / .pi },
            // Vision's `leftPupil` is on the image's left: the subject's right.
            leftPupil: marks.rightPupil.flatMap { points($0).first },
            rightPupil: marks.leftPupil.flatMap { points($0).first }
        )
        return (landmarks, marks.confidence)
    }

    /// The same pixels without colour attachments. Camera buffers carry an ICC
    /// colour space, and Vision colour-matches tagged buffers before every
    /// request: measured 2.5x slower on live frames (DECISIONS.md, step 10).
    /// Landmarks don't need colour accuracy; the compositor and the output
    /// keep the original, tagged buffer.
    static func untagged(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        guard CVBufferCopyAttachment(pb, kCVImageBufferCGColorSpaceKey, nil) != nil
                || CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil) != nil,
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
        else { return pb }
        var out: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &out) == kCVReturnSuccess, let out else { return pb }
        let view = out.takeRetainedValue()
        CVBufferRemoveAllAttachments(view)
        return view
    }

    /// Forget the followed face (after a seek, a camera switch, or for a
    /// still image). The next call always runs a full detection.
    public func reset() {
        clearTracking()
        idleSkipped = idleInterval
    }

    private func clearTracking() {
        idleSkipped = 0
        followed = nil
        tracked = nil
        trackedAnchor = nil
        lastAnchor = nil
        sinceDetect = 0
    }

    /// The largest face, unless the face followed last frame is still there
    /// and no other face is clearly larger.
    private func choose(_ faces: [VNFaceObservation]) -> VNFaceObservation? {
        guard let largest = faces.max(by: { area($0.boundingBox) < area($1.boundingBox) }) else { return nil }
        guard let followed,
              let same = faces.max(by: { iou($0.boundingBox, followed) < iou($1.boundingBox, followed) }),
              iou(same.boundingBox, followed) > 0.3
        else { return largest }
        return area(largest.boundingBox) > area(same.boundingBox) * Self.switchRatio ? largest : same
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = area(i)
        return inter / (area(a) + area(b) - inter)
    }

    private func centroid(_ p: [CGPoint]) -> CGPoint {
        guard !p.isEmpty else { return .zero }
        return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
    }
}
