@preconcurrency import AVFoundation
import os

/// Live camera frames as 32BGRA, newest-frame-wins.
public final class CameraSource: NSObject, FrameSource, @unchecked Sendable {
    public struct Config: Sendable {
        public var deviceID: String?
        public var width = 1280
        public var height = 720
        public var fps = 30.0
        public init(deviceID: String? = nil) { self.deviceID = deviceID }
    }

    private let config: Config
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "mirada.camera", qos: .userInteractive)
    private let continuation = OSAllocatedUnfairLock<AsyncThrowingStream<Frame, Error>.Continuation?>(initialState: nil)
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.jcantor.mirada", category: "camera")

    /// Frames the camera delivered, and frames it threw away because the
    /// consumer was still busy with an earlier one.
    private let counts = OSAllocatedUnfairLock(initialState: (captured: 0, dropped: 0))
    public var captured: Int { counts.withLock { $0.captured } }
    public var dropped: Int { counts.withLock { $0.dropped } }

    /// Name of the camera actually opened, once `frames()` has started.
    public private(set) var deviceName: String?
    private var device: AVCaptureDevice?

    /// System camera effects that run their own models on every frame and
    /// compete with Mirada for the Neural Engine and GPU.
    public var activeSystemEffects: [String] {
        guard let d = device else { return [] }
        var on: [String] = []
        if d.isPortraitEffectActive { on.append("portrait") }
        if d.isStudioLightActive { on.append("studio light") }
        if d.isCenterStageActive { on.append("center stage") }
        if #available(macOS 15.0, *), d.isBackgroundReplacementActive { on.append("background") }
        if AVCaptureDevice.reactionEffectGesturesEnabled { on.append("reaction gestures") }
        return on
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    public static func requestAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { return }
            throw MiradaError.cameraPermissionDenied
        default:
            throw MiradaError.cameraPermissionDenied
        }
    }

    public func frames() -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation.withLock { $0 = continuation }
            continuation.onTermination = { [weak self] _ in self?.stop() }
            Task {
                do {
                    try await Self.requestAccess()
                    try self.configure()
                    self.queue.async { self.session.startRunning() }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        continuation.withLock { $0 = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Ends the stream with an error when the camera goes away, so callers
    /// show a message instead of a frozen picture.
    private func watch(_ device: AVCaptureDevice) {
        let center = NotificationCenter.default
        let fail: @Sendable (String) -> Void = { [weak self] why in
            _ = self?.continuation.withLock { c in
                c?.finish(throwing: MiradaError.cameraUnavailable(why))
                c = nil
            }
        }
        let name = device.localizedName
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
            fail("\(name) was disconnected")
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            fail(error?.localizedDescription ?? "the camera stopped")
        })
    }

    private func configure() throws {
        let device = try CameraDevices.device(id: config.deviceID)
        deviceName = device.localizedName
        self.device = device
        watch(device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MiradaError.cameraUnavailable(error.localizedDescription)
        }
        guard session.canAddInput(input) else { throw MiradaError.cameraUnavailable("can't open \(device.localizedName)") }
        session.addInput(input)

        let size = selectFormat(on: device)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw MiradaError.cameraUnavailable("can't attach video output") }
        session.addOutput(output)

    }

    /// Picks the device format closest to the requested size that can do the
    /// requested frame rate, and returns the output size: the requested width
    /// with the format's own aspect ratio, so nothing is stretched.
    private func selectFormat(on device: AVCaptureDevice) -> (width: Int, height: Int) {
        let duration = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        func supportsRate(_ f: AVCaptureDevice.Format) -> Bool {
            f.videoSupportedFrameRateRanges.contains { $0.minFrameDuration <= duration && duration <= $0.maxFrameDuration }
        }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
        let candidates = device.formats.filter(supportsRate)
        let exact = candidates.first { dims($0).width == config.width && dims($0).height == config.height }
        let atLeast = candidates
            .filter { dims($0).width >= config.width }
            .min { dims($0).width < dims($1).width }
        let chosen = exact ?? atLeast ?? device.activeFormat

        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            if supportsRate(chosen) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            log.warning("could not configure camera format: \(error.localizedDescription)")
        }

        let d = dims(device.activeFormat)
        guard d.width > config.width else { return (Int(d.width), Int(d.height)) }
        let height = Int((Double(config.width) * Double(d.height) / Double(d.width) / 2).rounded()) * 2
        return (config.width, height)
    }
}

extension CameraSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        counts.withLock { $0.captured += 1 }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = Frame(pixelBuffer: pixelBuffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                          focalLength: Self.focalLength(pixelBuffer))
        let result = continuation.withLock { $0?.yield(frame) }
        if case .dropped = result { counts.withLock { $0.dropped += 1 } }   // replaced an unread frame
    }

    /// The lens focal length in pixels for this buffer, from the camera's
    /// per-frame metadata (`FocalLenIn35mmFilm`, converted by the 35 mm
    /// frame's diagonal, 43.27 mm). The FaceTime HD camera reports 27.7 mm:
    /// about 941 px at 1280x720.
    static func focalLength(_ pb: CVPixelBuffer) -> Double? {
        guard let md = CVBufferCopyAttachment(pb, "MetadataDictionary" as CFString, nil) as? [String: Any],
              let raw = md["FocalLenIn35mmFilm"] else { return nil }
        let f35 = (raw as? NSNumber)?.doubleValue ?? Double(String(describing: raw)) ?? 0
        guard f35 > 5, f35 < 300 else { return nil }
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        return f35 * (w * w + h * h).squareRoot() / (36.0 * 36 + 24 * 24).squareRoot()
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        counts.withLock { $0.dropped += 1 }
    }
}
