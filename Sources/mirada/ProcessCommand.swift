import ArgumentParser
import Foundation
import MiradaKit

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Correct gaze in a video or image file.",
        discussion: """
        Video keeps its frame timing, resolution, rotation and color tags; audio is \
        copied without re-encoding. Times accept seconds (12.5) or [hh:]mm:ss(.s).
        """
    )

    @Argument(help: "Input video or image.") var input: String
    @Option(name: .shortAndLong, help: "Output file (.mp4, .mov, .m4v for video; .png, .jpg, .heic for images).") var output: String
    @Option(name: .long, help: "Correction strength, 0 to 1 (default: saved setting).") var strength: Double?
    @Option(name: .long, help: "ane (Neural Engine, default) or cpu (exact fp32).") var backend: ModelBackend = .ane
    @Option(name: .long, help: "h264 or hevc (default: match the source).") var codec: VideoCodec?
    @Option(name: .long, help: "Video bitrate, e.g. 8000000 or 8M (default: match the source).") var bitrate: String?
    @Option(name: .long, help: "Start time.") var start: String?
    @Option(name: .long, help: "End time.") var end: String?
    @Flag(name: .customLong("no-audio"), help: "Drop the audio track.") var noAudio = false
    @Flag(name: .customLong("debug-overlay"), help: "Draw face box, eye points, crops, angle and timings into the output.") var debugOverlay = false
    @Flag(name: .long, help: "Write JSON lines (progress, then a report) to stdout.") var json = false
    @Flag(name: .long, help: "Replace the output file if it exists.") var force = false

    func validate() throws {
        if let strength, !(0...1).contains(strength) { throw ValidationError("--strength must be between 0 and 1") }
        if let bitrate, Self.parseBitrate(bitrate) == nil { throw ValidationError("--bitrate: use bits per second, e.g. 8000000 or 8M") }
        if let start, Self.parseTime(start) == nil { throw ValidationError("--start: use seconds or [hh:]mm:ss") }
        if let end, Self.parseTime(end) == nil { throw ValidationError("--end: use seconds or [hh:]mm:ss") }
    }

    struct ImageReport: Codable {
        var event = "done"
        var input: String
        var output: String
        var face: FaceState
        var angle: GazeAngle?
    }

    struct Event<T: Codable>: Codable {
        var event: String
        var data: T
    }

    func run() async throws {
        try await CLI.run {
            let inURL = URL(fileURLWithPath: input), outURL = URL(fileURLWithPath: output)
            guard FileManager.default.fileExists(atPath: inURL.path) else { throw MiradaError.inputMissing(inURL) }
            if inURL.standardizedFileURL == outURL.standardizedFileURL {
                throw MiradaError.invalidArgument("output must differ from input")
            }
            if FileManager.default.fileExists(atPath: outURL.path), !force {
                throw MiradaError.outputUnwritable(outURL, "file exists (use --force to replace)")
            }
            var settings = MiradaSettings.load()
            if let strength { settings.strength = strength }
            settings.enabled = true
            if debugOverlay { settings.debugOverlay = true }
            let pipeline = try GazePipeline(settings: settings, backend: backend)

            if StillImage.isImage(inURL) {
                let result = await pipeline.processStill(try StillImage.load(inURL))
                try StillImage.write(result.output, to: outURL)
                if json {
                    CLI.printJSON(ImageReport(input: inURL.path, output: outURL.path, face: result.face, angle: result.angle))
                } else if result.face != .tracking {
                    CLI.warn("no correction applied (\(result.face.rawValue)); wrote the image unchanged")
                }
                return
            }

            let options = FileJobOptions(codec: codec, bitrate: bitrate.flatMap(Self.parseBitrate),
                                         start: start.flatMap(Self.parseTime), end: end.flatMap(Self.parseTime),
                                         includeAudio: !noAudio)
            let progress = ProgressPrinter(json: json)
            let job = Task {
                try await FileJob.run(input: inURL, output: outURL, options: options, pipeline: pipeline) { progress.update($0) }
            }
            let interrupt = CLI.onInterrupt { job.cancel() }
            defer { interrupt.cancel() }

            let report: FileJobReport
            do {
                report = try await job.value
            } catch is CancellationError {
                progress.finish()
                CLI.warn("interrupted; removed the partial output")
                throw ExitCode(130)
            }
            progress.finish()
            if json {
                CLI.printJSON(Event(event: "done", data: report))
            } else {
                let pct = report.frames > 0 ? 100 * report.correctedFrames / report.frames : 0
                print(String(format: "%@  %d frames, %d%% corrected, %.1fx real time%@",
                             outURL.lastPathComponent, report.frames, pct, report.speed,
                             report.audioCopied ? ", audio copied" : ""))
            }
            if report.hdrSource {
                CLI.warn("HDR source: processed at 8 bits per channel with its color tags kept")
            }
        }
    }

    static func parseTime(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    static func parseBitrate(_ s: String) -> Int? {
        let lower = s.lowercased()
        let scale: Double = lower.hasSuffix("m") ? 1e6 : (lower.hasSuffix("k") ? 1e3 : 1)
        guard let v = Double(scale == 1 ? lower : String(lower.dropLast())), v > 0 else { return nil }
        return Int(v * scale)
    }
}

extension ModelBackend: ExpressibleByArgument {}
extension VideoCodec: ExpressibleByArgument {}

/// A single updating progress line on a terminal, JSON lines with --json,
/// nothing otherwise.
final class ProgressPrinter: @unchecked Sendable {
    private let json: Bool
    private let tty = isatty(STDERR_FILENO) != 0
    private let lock = NSLock()
    private var drew = false

    init(json: Bool) { self.json = json }

    func update(_ p: FileJobProgress) {
        lock.withLock {
            if json {
                CLI.printJSON(ProcessCommand.Event(event: "progress", data: p))
                return
            }
            guard tty else { return }
            let width = 24
            let filled = Int(p.fraction * Double(width))
            let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: width - filled)
            let eta = p.eta.map { String(format: " eta %d:%02d", Int($0) / 60, Int($0) % 60) } ?? ""
            CLI.stderr.write(Data(String(format: "\r[%@] %3d%%  %.0f fps%@   ", bar, Int(p.fraction * 100), p.fps, eta).utf8))
            drew = true
        }
    }

    func finish() {
        lock.withLock { if drew { CLI.stderr.write(Data("\n".utf8)) } }
    }
}
