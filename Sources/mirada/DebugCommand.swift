import ArgumentParser
import CoreGraphics
import CoreVideo
import Foundation
import MiradaKit

/// Developer tools. Hidden from `mirada --help`.
struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Developer measurements.",
        shouldDisplay: false,
        subcommands: [LandmarksJitter.self, ExportEyes.self, GazeTrace.self]
    )
}

/// Measures landmark jitter and Vision latency on a clip.
///
/// Jitter is the RMS of each point's second difference (px/frame²) over runs
/// of consecutive tracked frames. Smooth head motion has a small second
/// difference; detector noise does not.
struct LandmarksJitter: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "landmarks")

    @Argument(help: "Video file.") var input: String
    @Flag(name: .long) var json = false
    @Option(name: .long, help: "Write a PNG with landmarks and crop boxes for the frame at --at.") var snapshot: String?
    @Option(name: .long, help: "Seconds into the clip for --snapshot.") var at: Double = 0
    @Flag(name: .long, help: "Measure after Mirada's One Euro landmark smoothing.") var smooth = false
    @Option(name: .long) var minCutoff: Double = 1.2
    @Option(name: .long) var beta: Double = 0.6
    @Option(name: .long, help: "Run face detection every N frames (1 = every frame).") var redetect: Int = 6
    @Flag(name: .long, help: "Tag frames with the camera's Rec. 709 colour attachments (diagnostics).") var tagColor = false

    struct Report: Codable {
        var frames = 0
        var tracked = 0
        var visionP50ms = 0.0
        var visionP95ms = 0.0
        var jitterRMSpx = 0.0
        var jitterRMSFractionOfEyeLength = 0.0
        var meanEyeLengthPx = 0.0
    }

    func run() async throws {
        try await CLI.run {
            let source = try await FileSource(url: URL(fileURLWithPath: input))
            let tracker = FaceTracker(redetectInterval: redetect)
            let stats = StageStats(capacity: 100_000)
            var report = Report()
            var history: [[CGPoint]] = []
            var sumSq = 0.0, n = 0
            var eyeLen = 0.0
            var smoother = LandmarkSmoother(minCutoff: minCutoff, beta: beta)

            for try await frame in source.frames() {
                report.frames += 1
                if tagColor {
                    let pb = frame.pixelBuffer
                    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.itur_709)!, .shouldPropagate)
                }
                let sw = Stopwatch()
                let detected = try tracker.detect(frame)
                stats.record(.landmarks, ms: sw.ms)
                if detected == nil { smoother.reset() }
                let face = smooth ? detected.map { smoother.smooth($0, at: frame.time.seconds) } : detected
                if let snapshot, abs(frame.time.seconds - at) < 0.5 / 30, let image = DebugDrawing.uprightImage(frame),
                   let drawn = DebugDrawing.overlay(image, face: face) {
                    try DebugDrawing.writePNG(drawn, to: URL(fileURLWithPath: snapshot))
                }
                guard let face, abs(face.yaw ?? 0) < 25 else { history.removeAll(); continue }
                // A jump of more than one eye length means a different face or a cut.
                if let last = history.last, hypot(last[0].x - face.rightEye.outer.x, last[0].y - face.rightEye.outer.y) > abs(face.rightEye.outer.x - face.rightEye.inner.x) {
                    history.removeAll()
                    smoother.reset()
                }
                report.tracked += 1
                let pts = face.rightEye.ordered + face.leftEye.ordered
                eyeLen += Double(abs(face.rightEye.outer.x - face.rightEye.inner.x) + abs(face.leftEye.outer.x - face.leftEye.inner.x)) / 2
                history.append(pts)
                if history.count > 3 { history.removeFirst() }
                if history.count == 3 {
                    for k in 0..<pts.count {
                        let ax = history[2][k].x - 2 * history[1][k].x + history[0][k].x
                        let ay = history[2][k].y - 2 * history[1][k].y + history[0][k].y
                        sumSq += Double(ax * ax + ay * ay)
                        n += 1
                    }
                }
            }
            let s = stats.summary()[.landmarks]
            report.visionP50ms = s?.p50 ?? 0
            report.visionP95ms = s?.p95 ?? 0
            report.jitterRMSpx = n > 0 ? (sumSq / Double(n)).squareRoot() : 0
            report.meanEyeLengthPx = report.tracked > 0 ? eyeLen / Double(report.tracked) : 0
            report.jitterRMSFractionOfEyeLength = report.meanEyeLengthPx > 0 ? report.jitterRMSpx / report.meanEyeLengthPx : 0
            if json {
                CLI.printJSON(report)
            } else {
                print(String(format: "frames %d, frontal tracked %d\nvision p50 %.1f ms, p95 %.1f ms\njitter RMS %.2f px (%.1f%% of a %.1f px eye)",
                             report.frames, report.tracked, report.visionP50ms, report.visionP95ms,
                             report.jitterRMSpx, report.jitterRMSFractionOfEyeLength * 100, report.meanEyeLengthPx))
            }
        }
    }
}

/// Writes the model inputs Mirada builds for one frame, for golden tests:
/// `<name>.json` (crops, anchor points) and `<name>_{left,right}_rgb.bin`
/// (float32 little-endian, 48x64x3 RGB, HWC).
struct ExportEyes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export-eyes")

    @Argument(help: "Video file.") var input: String
    @Option(name: .long, help: "Seconds into the clip.") var at: Double
    @Option(name: .shortAndLong, help: "Output directory.") var output: String
    @Option(name: .long, help: "File name prefix.") var name: String

    struct Eye: Codable { var crop: [Int]; var anchorPoints: [[Int]]; var points: [[Double]] }
    struct Manifest: Codable { var source: String; var time: Double; var left: Eye; var right: Eye }

    func run() async throws {
        try await CLI.run {
            let source = try await FileSource(url: URL(fileURLWithPath: input))
            let tracker = FaceTracker()
            let dir = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for try await frame in source.frames() {
                let face = try tracker.detect(frame)
                guard abs(frame.time.seconds - at) < 0.5 / 30 else { continue }
                guard let face else { throw MiradaError.invalidArgument("no face at \(at)s") }
                let w = frame.mapping.uprightWidth, h = frame.mapping.uprightHeight
                var eyes: [Eye] = []
                for (side, points) in [("left", face.leftEye), ("right", face.rightEye)] {
                    guard let crop = EyeCrop.make(points, frameWidth: w, frameHeight: h) else {
                        throw MiradaError.invalidArgument("\(side) eye crop outside frame")
                    }
                    let rgb = EyeImage.sampleRGB(frame.pixelBuffer, mapping: frame.mapping, crop: crop)
                    try rgb.withUnsafeBytes { try Data($0).write(to: dir.appendingPathComponent("\(name)_\(side)_rgb.bin")) }
                    eyes.append(Eye(crop: [crop.top, crop.left, crop.height, crop.width], anchorPoints: crop.anchorList,
                                    points: points.ordered.map { [Double($0.x), Double($0.y)] }))
                }
                let manifest = Manifest(source: (input as NSString).lastPathComponent, time: frame.time.seconds, left: eyes[0], right: eyes[1])
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(manifest).write(to: dir.appendingPathComponent("\(name).json"))
                print("wrote \(name) at \(frame.time.seconds)s")
                return
            }
            throw MiradaError.invalidArgument("clip has no frame at \(at)s")
        }
    }
}

/// Prints head pose and iris offsets over a clip, to calibrate gaze estimation.
struct GazeTrace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gaze")
    @Argument(help: "Video file.") var input: String
    @Option(name: .long, help: "Print every Nth frame.") var every: Int = 5

    func run() async throws {
        try await CLI.run {
            let source = try await FileSource(url: URL(fileURLWithPath: input))
            let tracker = FaceTracker()
            var smoother = LandmarkSmoother()
            var n = 0
            print("   t    yaw  pitch |  uL     uR     vL     vR")
            for try await frame in source.frames() {
                n += 1
                guard let raw = try tracker.detect(frame) else { continue }
                let f = smoother.smooth(raw, at: frame.time.seconds)
                guard n % every == 0, let lp = f.leftPupil, let rp = f.rightPupil else { continue }
                let l = IrisOffset.of(f.leftEye, pupil: lp), r = IrisOffset.of(f.rightEye, pupil: rp)
                print(String(format: "%5.2f %6.1f %6.1f | %+.3f %+.3f %+.3f %+.3f", frame.time.seconds, f.yaw ?? .nan, f.pitch ?? .nan, l.u, r.u, l.v, r.v))
            }
        }
    }
}
