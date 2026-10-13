import AppKit
import ArgumentParser
import Foundation
import MiradaKit

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run live correction headless and publish it as a virtual camera.",
        discussion: """
        Publishes to Mirada Camera when its extension is active, otherwise to OBS Virtual \
        Camera (select that camera in Zoom, Meet, Teams or FaceTime). Ctrl-C stops.
        """
    )

    @Option(name: .long, help: "Camera unique ID or name (see `mirada devices`).") var camera: String?
    @Option(name: .long, help: "Correction strength, 0 to 1 (default: saved setting).") var strength: Double?
    @Option(name: .long, help: "ane (Neural Engine, default) or cpu.") var backend: ModelBackend = .ane
    @Option(name: .long, help: "Virtual camera: mirada or obs (default: best available).") var target: VirtualCameraTarget?
    @Flag(name: .customLong("no-virtual-camera"), help: "Don't publish; just run the pipeline.") var noVirtualCamera = false
    @Flag(name: .long, help: "Show a preview window.") var preview = false
    @Flag(name: .long, help: "Print per-stage latency (p50/p95) and memory every 5 s and at exit.") var stats = false
    @Flag(name: .customLong("debug-overlay"), help: "Draw face box, eye points, crops, angle and timings into the output.") var debugOverlay = false
    @Flag(name: .long, help: "Write JSON lines to stdout.") var json = false
    @Option(name: .long, help: "Stop after this many seconds.") var seconds: Double?
    @Option(name: .long, help: "Use a video file, looped in real time, instead of a camera.") var simulate: String?

    func validate() throws {
        if let strength, !(0...1).contains(strength) { throw ValidationError("--strength must be between 0 and 1") }
    }

    struct Tick: Codable {
        var event: String
        var seconds: Double
        var frames: Int
        var fps: Double
        var face: FaceState
        var memoryMB: Double
        var target: VirtualCameraTarget?
        var sent: Int?
        var dropped: Int?
        var stages: [String: StageSummary]
    }

    func run() async throws {
        try await CLI.run {
            var settings = MiradaSettings.load()
            if let strength { settings.strength = strength }
            if let camera { settings.cameraID = camera }
            if debugOverlay { settings.debugOverlay = true }
            let pipeline = try GazePipeline(settings: settings, backend: backend)

            var sinks: [any FrameSink] = []
            var vcam: VirtualCameraSink?
            if !noVirtualCamera {
                vcam = try VirtualCameraSink(preferred: target)
                sinks.append(vcam!)
                if !json { CLI.warn("publishing to \(vcam!.target.deviceName)") }
            }
            let window = preview ? await PreviewWindow.open() : nil
            if let window { sinks.append(window) }

            let source: any FrameSource = simulate.map { PacedFileSource(url: URL(fileURLWithPath: $0)) }
                ?? CameraSource(config: CameraSource.Config(deviceID: settings.cameraID))

            let clock = Stopwatch()
            let counter = FrameCounter()
            let job = Task {
                try await PipelineRunner.run(source: source, pipeline: pipeline, sinks: sinks) { p in counter.add(p.face) }
            }
            let interrupt = CLI.onInterrupt { job.cancel() }
            defer { interrupt.cancel() }

            let reporter = Task {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    if stats || json { report("tick", clock, counter, pipeline, vcam) }
                }
            }
            let deadline = seconds.map { s in
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
                    job.cancel()
                }
            }
            defer { deadline?.cancel() }
            if let window {
                // Pump AppKit events until the window closes or the run ends.
                let finished = DoneFlag()
                let watcher = Task.detached { _ = try? await job.value; finished.set() }
                await window.pumpEvents { finished.isSet }
                job.cancel()
                watcher.cancel()
            }
            do {
                try await job.value
            } catch is CancellationError {
            } catch let e as MiradaError {
                reporter.cancel()
                throw e
            } catch {
                reporter.cancel()
                throw MiradaError.internalError(error.localizedDescription)
            }
            reporter.cancel()
            for sink in sinks { try? await sink.finish() }
            if stats || json { report("done", clock, counter, pipeline, vcam) }
        }
    }

    func report(_ event: String, _ clock: Stopwatch, _ counter: FrameCounter, _ pipeline: GazePipeline, _ vcam: VirtualCameraSink?) {
        let secs = clock.ms / 1000
        let (frames, face) = counter.snapshot()
        let summary = pipeline.stats.summary()
        let tick = Tick(event: event, seconds: secs, frames: frames, fps: Double(frames) / max(secs, 1e-3), face: face,
                        memoryMB: ProcessMemory.residentMB(), target: vcam?.target, sent: vcam?.client.sent, dropped: vcam?.client.dropped,
                        stages: Dictionary(uniqueKeysWithValues: summary.map { ($0.key.rawValue, $0.value) }))
        if json {
            CLI.printJSON(tick)
            return
        }
        let order: [Stage] = [.landmarks, .model, .compose, .total]
        let stages = order.compactMap { s in summary[s].map { String(format: "%@ %.1f/%.1f", s.rawValue, $0.p50, $0.p95) } }.joined(separator: "  ")
        CLI.warn(String(format: "%@ %.0fs %.1f fps  %@ ms (p50/p95)  %.0f MB  face %@", event, secs, tick.fps, stages, tick.memoryMB, face.rawValue))
    }
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var face: FaceState = .noFace

    func add(_ f: FaceState) { lock.withLock { frames += 1; face = f } }
    func snapshot() -> (Int, FaceState) { lock.withLock { (frames, face) } }
}

extension VirtualCameraTarget: ExpressibleByArgument {}

/// A minimal AppKit window showing the corrected output, for `--preview`.
@MainActor
final class PreviewWindow: NSObject, FrameSink, NSWindowDelegate, @unchecked Sendable {
    private let window: NSWindow
    private var closed = false
    /// Touched only on the main thread, via the main dispatch queue (drained
    /// while events are pumped).
    nonisolated(unsafe) private let layer = CALayer()

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "mirada run — preview"
        let view = NSView()
        view.wantsLayer = true
        view.layer = layer
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        window.contentView = view
        window.delegate = self
        window.center()
    }

    static func open() async -> PreviewWindow {
        NSApplication.shared.setActivationPolicy(.regular)
        let w = PreviewWindow()
        w.window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return w
    }

    /// Handles AppKit events until the window closes or `done()` is true,
    /// yielding between batches so other main-actor work keeps running.
    func pumpEvents(until done: @escaping @Sendable () -> Bool) async {
        NSApplication.shared.finishLaunching()
        while !closed, !done() {
            while let event = NSApplication.shared.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            await Task.yield()
        }
        window.orderOut(nil)
    }

    nonisolated func consume(_ frame: ProcessedFrame) async throws {
        guard let surface = CVPixelBufferGetIOSurface(frame.output.pixelBuffer)?.takeUnretainedValue() else { return }
        let box = UncheckedBox((layer, surface))
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            box.value.0.contents = box.value.1
            CATransaction.commit()
        }
    }

    nonisolated func finish() async throws {}

    func windowWillClose(_ notification: Notification) {
        closed = true
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A thread-safe one-way flag.
final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
