import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os

/// Detect -> smooth -> angle -> crop -> model -> compose, one frame at a time.
///
/// Never stalls and never goes black: when anything fails, the original frame
/// passes through. With no face, the output *is* the input buffer.
public actor GazePipeline {
    public nonisolated let stats = StageStats()
    public private(set) var settings: MiradaSettings

    private let tracker = FaceTracker()
    private let model: GazeModel?
    private let compositor: MetalCompositor
    private var smoother = LandmarkSmoother()
    private var gate = FaceGate()
    private var gazeTracker = GazeTracker()

    /// Correction fade, smoothed with a One Euro filter (beta 0: a plain
    /// adaptive-rate low-pass) so it ramps instead of popping. Fading in is
    /// gentle; fading out is quick enough to beat a closing eyelid.
    private var fadeFilter = OneEuroFilter(minCutoff: GazePipeline.fadeInHz, beta: 0)
    static let fadeInHz = 2.0
    static let fadeOutHz = 6.0
    private var fade = 0.0
    private var lastTime: Double?
    private let log = Logger(subsystem: "com.jcantor.mirada", category: "pipeline")

    /// Counts frames that fell back to pass-through because a stage failed.
    public private(set) var failures = 0

    /// Full face detections so far (the rest of the frames only track).
    public var detections: Int { tracker.detections }

    /// Mean milliseconds per face-rectangles and per landmarks request so far.
    public var visionSplit: (rectangles: Double, landmarks: Double) {
        (tracker.rectanglesMs / Double(max(1, tracker.detections)), tracker.landmarksMs / Double(max(1, tracker.landmarkRuns)))
    }

    public init(settings: MiradaSettings = .load(), backend: ModelBackend = .ane) throws {
        self.settings = settings
        compositor = try MetalCompositor()
        model = try GazeModel(backend: backend)
    }

    public func update(_ settings: MiradaSettings) {
        self.settings = settings
    }

    /// Forget tracking state (after a seek, a camera switch, or a cut).
    public func reset() {
        tracker.reset()
        smoother.reset()
        gate.reset()
        gazeTracker.reset()
        fadeFilter.reset()
        fade = 0
        lastTime = nil
    }

    /// A still image: no history, full correction at once (if the face is
    /// open-eyed and frontal).
    public func processStill(_ frame: Frame) -> ProcessedFrame {
        reset()
        _ = fadeFilter.filter(settings.enabled ? 1 : 0, at: -1)
        return process(Frame(pixelBuffer: frame.pixelBuffer, time: .zero, orientation: frame.orientation))
    }

    public func process(_ frame: Frame) -> ProcessedFrame {
        let total = Stopwatch()
        defer { stats.record(.total, ms: total.ms) }
        frameMs = (0, 0, 0)
        rawAngle = nil
        gazeDeviation = nil
        let result = correct(frame)
        guard settings.debugOverlay else { return result }
        return decorate(result)
    }

    /// Per-frame timings and the unscaled angle, for the debug overlay.
    private var frameMs = (vision: 0.0, model: 0.0, compose: 0.0)
    private var rawAngle: GazeAngle?
    private var gazeDeviation: GazeAngle?

    /// "I'm looking at the middle of the screen now." Returns the reading to
    /// save as the calibrated middle (nil without a usable face).
    public func captureGazeCentre() -> GazeCentre? {
        gazeTracker.captureCentre(now: lastTime ?? 0)
    }

    // MARK: focal length and gaze calibration

    private var recentIOD: [Double] = []
    private var lastCentre: GazeAngle?
    private var lastFace: FaceLandmarks?

    /// Where the focal length came from: "measured", "camera" (lens metadata)
    /// or "assumed" (eye spacing at a typical 55 cm).
    public private(set) var focalSource = "assumed"
    public private(set) var focalLength: Double?

    /// The camera geometry in use: your measurement, else what the camera
    /// reports about its lens, else eye spacing at an assumed typical distance.
    private func effectiveCamera(_ face: FaceLandmarks, _ frame: Frame) -> CameraGeometry {
        var c = settings.camera
        recentIOD.append(face.interocularPixels)
        if recentIOD.count > 90 { recentIOD.removeFirst(recentIOD.count - 90) }
        if c.focalCalibrated {
            focalSource = "measured"
        } else if let f = frame.focalLength {
            c.focalLength = f
            focalSource = "camera"
        } else {
            let median = recentIOD.sorted()[recentIOD.count / 2]
            c.focalLength = median * CameraGeometry.assumedDistance / c.ipd
            focalSource = "assumed"
        }
        focalLength = c.focalLength
        return c
    }

    /// Current camera-to-eyes distance in cm, from eye spacing and the focal length in use.
    public var estimatedDistance: Double? {
        guard let f = focalLength, !recentIOD.isEmpty else { return nil }
        return f * settings.camera.ipd / recentIOD.sorted()[recentIOD.count / 2]
    }

    /// Call while the user looks straight at the camera: returns the vertical
    /// gain that makes this gaze read as "no correction needed", or nil if
    /// there is no usable face or the reading is too small to trust.
    public func gainForLookingAtCamera() -> Double? {
        guard lastFace != nil, let centre = lastCentre, let off = gazeTracker.offsetFromCentre,
              abs(off.v) > 0.004, centre.vertical > 2 else { return nil }
        // g × -v (radians) must equal the centre-to-camera vertical angle.
        let g = (centre.vertical * .pi / 180) / -off.v
        return (1...20).contains(g) ? g : nil
    }

    /// Draws the decision readout into the output. Never into the input:
    /// when the frame passed through, the overlay goes on a copy.
    private func decorate(_ p: ProcessedFrame) -> ProcessedFrame {
        let target: CVPixelBuffer
        if p.output.pixelBuffer === p.original.pixelBuffer {
            guard let copy = try? compositor.compose(p.original, patches: []) else { return p }
            target = copy
        } else {
            target = p.output.pixelBuffer
        }
        let info = DebugInfo(face: p.landmarks, state: p.face, fade: p.fade, strength: settings.strength, enabled: settings.enabled,
                             angle: p.angle, rawAngle: rawAngle, gaze: gazeDeviation, trackerMode: tracker.lastMode,
                             visionMs: frameMs.vision, modelMs: frameMs.model, composeMs: frameMs.compose)
        var shown = info
        shown.gazeCalibrated = settings.camera.gazeCentre != nil
        shown.focal = focalLength.map { String(format: "f %.0f px (%@)  ~%.0f cm away", $0, focalSource, estimatedDistance ?? 0) }
        DebugOverlay.draw(shown, into: target, mapping: p.original.mapping)
        return ProcessedFrame(output: Frame(pixelBuffer: target, time: p.original.time, orientation: p.original.orientation),
                              original: p.original, face: p.face, angle: p.angle, fade: p.fade, landmarks: p.landmarks)
    }

    private func correct(_ frame: Frame) -> ProcessedFrame {
        var t = frame.time.seconds
        if !t.isFinite { t = (lastTime ?? 0) + 1.0 / 30 }
        if let last = lastTime, t < last - 0.5 || t > last + 2 { reset() }   // seek or long gap
        lastTime = t

        // Landmarks.
        let detect = Stopwatch()
        let raw: FaceLandmarks?
        do {
            raw = try tracker.detect(frame)
        } catch {
            failures += 1
            log.error("landmarks failed: \(error.localizedDescription)")
            return .passthrough(frame)
        }
        frameMs.vision = detect.ms
        stats.record(.landmarks, ms: frameMs.vision)
        guard let raw else {
            smoother.reset()
            fadeFilter.reset()
            fade = 0
            return .passthrough(frame, face: .noFace)
        }
        let face = smoother.smooth(raw, at: t)
        let state = gate.classify(face)
        // Where you are actually looking, relative to your usual direction.
        gazeTracker.gainH = settings.camera.gazeGainH
        gazeTracker.gainV = settings.camera.gazeGainV
        gazeTracker.fixedCentre = settings.camera.gazeCentre
        let deviation = settings.followGaze ? gazeTracker.deviation(face, at: t) : nil
        lastFace = face
        gazeDeviation = deviation
        // Eye turns don't pause correction (JC wants his eyes brought back from
        // the screen's edges); head turns and blinks still do (FaceGate). The
        // needed angle is clamped to the model's training range below.
        // A newly found face ramps in from zero instead of snapping on.
        if fadeFilter.value == nil { _ = fadeFilter.filter(0, at: t - 1.0 / 30) }

        // Fade toward 1 while tracking an open, frontal face; toward 0 otherwise.
        let target = settings.enabled && state == .tracking ? 1.0 : 0.0
        fadeFilter.minCutoff = target < fade ? Self.fadeOutHz : Self.fadeInHz
        fade = min(1, max(0, fadeFilter.filter(target, at: t)))
        if fade < 0.01 { fade = 0 }

        let size = CGSize(width: frame.mapping.uprightWidth, height: frame.mapping.uprightHeight)
        let estimate = GazeGeometry.estimate(leftCenter: face.leftEye.center, rightCenter: face.rightEye.center, frameSize: size, camera: effectiveCamera(face, frame))
        lastCentre = estimate.angle
        // Screen-centre-to-camera, minus how far you already look from centre.
        let d = deviation ?? .zero
        let needed = GazeAngle(vertical: estimate.angle.vertical - d.vertical, horizontal: estimate.angle.horizontal - d.horizontal)
        let angle = GazeGeometry.clamp(needed).scaled(by: settings.strength * fade)
        rawAngle = needed

        guard fade > 0, settings.strength > 0, let model,
              let lc = EyeCrop.make(face.leftEye, frameWidth: Int(size.width), frameHeight: Int(size.height)),
              let rc = EyeCrop.make(face.rightEye, frameWidth: Int(size.width), frameHeight: Int(size.height))
        else {
            return ProcessedFrame(output: frame, original: frame, face: state, angle: nil, fade: fade, landmarks: face)
        }

        do {
            let infer = Stopwatch()
            let map = frame.mapping
            let left = EyeInput(rgb: EyeImage.sampleRGB(frame.pixelBuffer, mapping: map, crop: lc), crop: lc)
            let right = EyeInput(rgb: EyeImage.sampleRGB(frame.pixelBuffer, mapping: map, crop: rc), crop: rc)
            let warps = try model.predict(left: left, right: right, angle: angle)
            frameMs.model = infer.ms
            stats.record(.model, ms: frameMs.model)

            let compose = Stopwatch()
            let out = try compositor.compose(frame, patches: [
                WarpPatch(crop: lc, warp: warps.left, alpha: Float(fade)),
                WarpPatch(crop: rc, warp: warps.right, alpha: Float(fade)),
            ])
            frameMs.compose = compose.ms
            stats.record(.compose, ms: frameMs.compose)
            return ProcessedFrame(output: Frame(pixelBuffer: out, time: frame.time, orientation: frame.orientation),
                                  original: frame, face: state, angle: angle, fade: fade, landmarks: face)
        } catch {
            failures += 1
            log.error("correction failed: \(error.localizedDescription)")
            return ProcessedFrame(output: frame, original: frame, face: state, angle: nil, fade: fade, landmarks: face)
        }
    }
}

/// Pulls frames from a source through the pipeline into every sink.
public enum PipelineRunner {
    public static func run(source: some FrameSource, pipeline: GazePipeline, sinks: [any FrameSink],
                           onFrame: (@Sendable (ProcessedFrame) -> Void)? = nil) async throws {
        do {
            for try await frame in source.frames() {
                try Task.checkCancellation()
                let processed = await pipeline.process(frame)
                for sink in sinks { try await sink.consume(processed) }
                onFrame?(processed)
            }
        } catch {
            for sink in sinks { try? await sink.finish() }
            throw error
        }
        for sink in sinks { try await sink.finish() }
    }
}
