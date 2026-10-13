import AppKit
import MiradaKit
import Observation
import os
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Mode: String, CaseIterable { case live, file }
    enum Compare: String, CaseIterable { case split, flip }

    enum CameraState: Equatable {
        case starting
        case running(String)
        case failed(String)
        case stopped
    }

    enum FileState: Equatable {
        case empty
        case ready(URL)
        case running(URL, FileJobProgress)
        case done(input: URL, output: URL, summary: String)
        case failed(String)

        static func == (a: FileState, b: FileState) -> Bool { String(describing: a) == String(describing: b) }
    }

    // UI state
    var mode: Mode = .live { didSet { modeChanged(from: oldValue) } }
    var compare: Compare = .split
    var showBefore = false
    var split: CGFloat = 0.5
    var calibrationOpen = false

    // Live state
    var cameraState: CameraState = .stopped
    var cameras: [CameraDeviceInfo] = []
    var face: FaceState = .noFace
    var fade = 0.0
    var landmarks: FaceLandmarks?
    var frameSize: CGSize = .zero
    var statsLine = ""

    // Virtual camera
    enum VirtualCameraState: Equatable {
        case off
        case publishing(VirtualCameraTarget)
        case unavailable(String)
    }
    var virtualCamera: VirtualCameraState = .off
    let extensions = ExtensionManager()

    // File state
    var fileState: FileState = .empty

    /// Still before/after images instead of the camera (screenshots).
    struct Still {
        var before: NSImage
        var after: NSImage
    }
    var still: Still?
    var isSnapshot: Bool { still != nil }
    /// Diagnostic launches (probe, self-test) must not start live or publish.
    static let isDiagnosticRun = CommandLine.arguments.contains { ["--probe-virtual-camera", "--self-test-virtual-camera"].contains($0) }

    /// Recent interocular distances (px), for measuring the focal length.
    private var recentIOD: [Double] = []

    var settings: MiradaSettings {
        didSet {
            guard settings != oldValue else { return }
            try? settings.save()
            let s = settings
            Task { await pipeline?.update(s) }
            if mode == .live, settings.cameraID != oldValue.cameraID || settings.publishVirtualCamera != oldValue.publishVirtualCamera {
                startLive()
            }
        }
    }

    let after = PreviewFeed()
    let before = PreviewFeed()
    /// Extra live outputs (the virtual camera), fed every processed frame.
    var extraSinks: [any FrameSink] = []

    private var pipeline: GazePipeline?
    private var liveTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.jcantor.mirada", category: "app")

    init() {
        settings = AppModel.initialSettings()
        cameras = CameraDevices.list().filter { !$0.isVirtual }
    }

    /// Saved settings, or first-run defaults (camera position from the
    /// built-in display's physical size).
    static func initialSettings() -> MiradaSettings { MiradaSettings.load() }

    func toggleCorrection() { settings.enabled.toggle() }

    var isLocked: Bool { settings.enabled && face == .tracking && fade > 0.9 }

    var statusText: String {
        switch cameraState {
        case .starting: return "// waking"
        case .failed: return "// no camera"
        case .stopped: return "// resting"
        case .running:
            guard settings.enabled else { return "// correction off" }
            switch face {
            case .tracking: return fade > 0.9 ? "// gaze locked" : "// locking on"
            case .blinking: return "// blink"
            case .lookingAway: return "// looking away"
            case .tooSmall: return "// come closer"
            case .noFace: return "// looking for you"
            }
        }
    }

    // MARK: calibration

    var canMeasure: Bool { face == .tracking && recentIOD.count >= 10 }

    /// Camera-to-eyes distance (cm), focal length in use and where it came from.
    var distanceCM: Double?
    var focalLength: Double?
    var focalSource = "assumed"

    /// f = interocular pixels × distance / interpupillary distance, averaged
    /// over the last second of frames. Saves and returns the new focal length.
    func measureFocalLength(distanceCM: Double) -> Double? {
        guard canMeasure else { return nil }
        let sorted = recentIOD.sorted()
        let median = sorted[sorted.count / 2]
        let f = median * distanceCM / settings.camera.ipd
        guard f.isFinite, (200...4000).contains(f) else { return nil }
        settings.camera.focalLength = f
        settings.camera.focalCalibrated = true
        return f
    }

    /// Call while looking straight at the camera: tunes the vertical gaze gain
    /// so that this reads as "no correction needed". Returns the new gain.
    func calibrateLookingAtCamera() async -> Double? {
        guard let p = pipeline, let g = await p.gainForLookingAtCamera() else { return nil }
        settings.camera.gazeGainV = g
        return g
    }

    /// "I'm looking at the middle of the screen now."
    func recenterGaze() {
        guard let p = pipeline else { return }
        Task {
            if let c = await p.captureGazeCentre() { settings.camera.gazeCentre = c }
        }
    }

    func resetCalibration() {
        settings.camera = MiradaSettings.firstRunDefaults().camera
    }

    private func noteIOD(_ face: FaceLandmarks?, state: FaceState) {
        guard let face, state == .tracking else { return }
        recentIOD.append(face.interocularPixels)
        if recentIOD.count > 30 { recentIOD.removeFirst(recentIOD.count - 30) }
    }

    func setStrength(_ v: Double) { settings.strength = min(1, max(0, v)) }

    // MARK: live

    func startLive() {
        liveTask?.cancel()
        cameraState = .starting
        cameras = CameraDevices.list().filter { !$0.isVirtual }
        extensions.refresh()
        openVirtualCamera()
        let settings = settings
        let feeds = (after, before)
        let sinks = extraSinks
        let log = log
        let pipeline: GazePipeline
        do {
            pipeline = try livePipeline(settings)
            Task { await pipeline.reset() }
        } catch {
            cameraState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        liveTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Hidden: `--simulate <video>` plays a file as the camera (diagnostics).
                let args = CommandLine.arguments
                let simulated = args.firstIndex(of: "--simulate").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                let camera = CameraSource(config: CameraSource.Config(deviceID: settings.cameraID))
                let source: any FrameSource = simulated.map { PacedFileSource(url: URL(fileURLWithPath: $0)) } ?? camera
                // Hidden: `--with-camera` also runs the camera and discards its frames (diagnostics).
                if simulated != nil, args.contains("--with-camera") {
                    Task.detached { for try await _ in camera.frames() {} }
                }
                var count = 0
                var lastUI = Date.distantPast
                for try await frame in source.frames() {
                    if Task.isCancelled { break }
                    let p = await pipeline.process(frame)
                    feeds.0.show(p.output.pixelBuffer)
                    feeds.1.show(p.original.pixelBuffer)
                    for sink in sinks { try? await sink.consume(p) }
                    count += 1
                    if count % 30 == 0, let a = p.angle {
                        log.info("gaze: correction V \(a.vertical, format: .fixed(precision: 1)) H \(a.horizontal, format: .fixed(precision: 1)) face \(p.face.rawValue, privacy: .public)")
                    } else if count % 30 == 0 {
                        log.info("gaze: no correction, face \(p.face.rawValue, privacy: .public)")
                    }
                    if count % 300 == 0 {
                        let detections = await pipeline.detections
                        let split = await pipeline.visionSplit
                        log.info("effects: \(camera.activeSystemEffects.joined(separator: ", "), privacy: .public)")
                        let pb = frame.pixelBuffer
                        let attachments = (CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any]).map { "\($0)" } ?? "none"
                        if count == 300, let md = CVBufferCopyAttachment(pb, "MetadataDictionary" as CFString, nil) {
                            log.info("metadata: \(String(describing: md), privacy: .public)")
                        }
                        let fourcc = CVPixelBufferGetPixelFormatType(pb)
                        log.info("buffer: \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) fmt \(fourcc) bpr \(CVPixelBufferGetBytesPerRow(pb)) iosurface \(CVPixelBufferGetIOSurface(pb) != nil) attach \(attachments, privacy: .public)")
                        log.info("camera: \(camera.captured) captured, \(camera.dropped) dropped")
                        log.info("live: \(count) frames, \(detections) detections (rect \(split.rectangles, format: .fixed(precision: 1)) ms, landmarks \(split.landmarks, format: .fixed(precision: 1)) ms), face \(p.face.rawValue, privacy: .public), fade \(p.fade, format: .fixed(precision: 2)), \(AppModel.format(pipeline.stats.summary()), privacy: .public)")
                    }
                    // UI state at most ~15 times a second.
                    if count == 1 || Date().timeIntervalSince(lastUI) > 1.0 / 15 {
                        lastUI = Date()
                        let name = simulated == nil ? (camera.deviceName ?? "camera") : "simulated"
                        let size = CGSize(width: frame.mapping.uprightWidth, height: frame.mapping.uprightHeight)
                        let line = AppModel.format(pipeline.stats.summary())
                        let lens = (await pipeline.estimatedDistance, await pipeline.focalLength, await pipeline.focalSource)
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            if case .running = self.cameraState {} else { self.cameraState = .running(name) }
                            self.face = p.face
                            self.fade = p.fade
                            self.landmarks = p.landmarks
                            self.noteIOD(p.landmarks, state: p.face)
                            self.frameSize = size
                            self.statsLine = line
                            (self.distanceCM, self.focalLength, self.focalSource) = lens
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                log.error("live failed: \(error.localizedDescription)")
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { [weak self] in self?.cameraState = .failed(message) }
            }
        }
    }

    /// (Re)opens the virtual camera sink according to settings.
    private func openVirtualCamera() {
        for sink in extraSinks { Task { try? await sink.finish() } }
        extraSinks = []
        guard settings.publishVirtualCamera else {
            virtualCamera = .off
            return
        }
        do {
            let sink = try VirtualCameraSink()
            extraSinks = [sink]
            virtualCamera = .publishing(sink.target)
        } catch {
            virtualCamera = .unavailable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func stopLive() {
        for sink in extraSinks { Task { try? await sink.finish() } }
        extraSinks = []
        virtualCamera = .off
        liveTask?.cancel()
        liveTask = nil
        cameraState = .stopped
        face = .noFace
        landmarks = nil
    }

    private func livePipeline(_ settings: MiradaSettings) throws -> GazePipeline {
        if let pipeline { return pipeline }
        let p = try GazePipeline(settings: settings)
        pipeline = p
        return p
    }

    private func modeChanged(from old: Mode) {
        guard mode != old else { return }
        if mode == .live { startLive() } else { stopLive() }
    }

    nonisolated static func format(_ s: [Stage: StageSummary]) -> String {
        let parts: [(String, Stage)] = [("vision", .landmarks), ("model", .model), ("compose", .compose), ("total", .total)]
        let text = parts.compactMap { label, stage in
            s[stage].map { String(format: "%@ %.1f", label, $0.p50) }
        }.joined(separator: " · ")
        return text.isEmpty ? "" : text + " ms p50"
    }

    // MARK: file

    func chooseFile(_ url: URL) {
        if case .running = fileState { return }
        fileState = .ready(url)
    }

    func saveCorrectedCopy() {
        guard case .ready(let input) = fileState else { return }
        let panel = NSSavePanel()
        let ext = StillImage.isImage(input) ? input.pathExtension : "mp4"
        panel.nameFieldStringValue = input.deletingPathExtension().lastPathComponent + "-mirada." + ext
        panel.directoryURL = input.deletingLastPathComponent()
        guard panel.runModal() == .OK, let output = panel.url else { return }
        process(input, to: output)
    }

    func process(_ input: URL, to output: URL) {
        var settings = settings
        settings.enabled = true
        fileState = .running(input, FileJobProgress(fraction: 0, frames: 0, fps: 0, eta: nil))
        fileTask = Task { [weak self] in
            do {
                let pipeline = try GazePipeline(settings: settings)
                let summary: String
                if StillImage.isImage(input) {
                    let result = await pipeline.processStill(try StillImage.load(input))
                    try StillImage.write(result.output, to: output)
                    summary = result.face == .tracking ? "// eyes on camera" : "// no correction (\(result.face.rawValue))"
                } else {
                    let model = self
                    let report = try await FileJob.run(input: input, output: output, options: FileJobOptions(), pipeline: pipeline) { p in
                        Task { @MainActor in model?.fileProgress(input, p) }
                    }
                    let pct = report.frames > 0 ? 100 * report.correctedFrames / report.frames : 0
                    summary = String(format: "// %d frames · %d%% corrected · %.1fx real time", report.frames, pct, report.speed)
                }
                self?.fileState = .done(input: input, output: output, summary: summary)
            } catch is CancellationError {
                self?.fileState = .ready(input)
            } catch {
                self?.fileState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func fileProgress(_ input: URL, _ p: FileJobProgress) {
        if case .running = fileState { fileState = .running(input, p) }
    }

    func cancelFile() {
        fileTask?.cancel()
    }
}
