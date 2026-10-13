@preconcurrency import AVFoundation
import Foundation

public enum VideoCodec: String, Sendable, Codable, CaseIterable {
    case h264, hevc

    var avType: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
}

public struct FileJobOptions: Sendable {
    /// nil: same as the source when it is H.264 or HEVC, else H.264.
    public var codec: VideoCodec?
    /// Bits per second; nil: the source's data rate (at least 0.08 bits per pixel).
    public var bitrate: Int?
    public var start: Double?
    public var end: Double?
    public var includeAudio = true

    public init(codec: VideoCodec? = nil, bitrate: Int? = nil, start: Double? = nil, end: Double? = nil, includeAudio: Bool = true) {
        self.codec = codec
        self.bitrate = bitrate
        self.start = start
        self.end = end
        self.includeAudio = includeAudio
    }
}

public struct FileJobProgress: Sendable, Codable {
    public let fraction: Double
    public let frames: Int
    public let fps: Double
    /// Seconds remaining, once there is enough data to estimate.
    public let eta: Double?

    public init(fraction: Double, frames: Int, fps: Double, eta: Double?) {
        self.fraction = fraction
        self.frames = frames
        self.fps = fps
        self.eta = eta
    }
}

public struct FileJobReport: Sendable, Codable {
    public var input: String
    public var output: String
    public var frames: Int
    public var correctedFrames: Int
    public var mediaSeconds: Double
    public var elapsedSeconds: Double
    /// Media seconds processed per wall-clock second (>1 is faster than real time).
    public var speed: Double
    public var codec: VideoCodec
    public var audioCopied: Bool
    public var hdrSource: Bool
    public var stages: [String: StageSummary]
}

/// File in, file out: video through the gaze pipeline, audio copied as-is.
///
/// Video and audio are written by two concurrent tasks that each wait for
/// their writer input to be ready, so AVAssetWriter can interleave them
/// without deadlocking. Frames keep their source timestamps (variable frame
/// rate survives), the track keeps its rotation transform and color tags.
public enum FileJob {
    public static func run(input: URL, output: URL, options: FileJobOptions, pipeline: GazePipeline,
                           progress: (@Sendable (FileJobProgress) -> Void)? = nil) async throws -> FileJobReport {
        let range = try timeRange(options)
        let source = try await FileSource(url: input, timeRange: range)
        let info = source.info
        let fileType: AVFileType = switch output.pathExtension.lowercased() {
        case "mov": .mov
        case "m4v": .m4v
        default: .mp4
        }
        let codec: VideoCodec
        if let chosen = options.codec { codec = chosen } else { codec = try await sourceCodec(source.asset) }

        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        } catch {
            throw MiradaError.outputUnwritable(output, error.localizedDescription)
        }

        let w = Int(info.naturalSize.width), h = Int(info.naturalSize.height)
        let fps = Double(info.nominalFrameRate > 0 ? info.nominalFrameRate : 30)
        let floorRate = Int(0.08 * Double(w * h) * fps)
        let bitrate = options.bitrate ?? max(Int(info.estimatedDataRate), floorRate)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avType,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String: Any],
        ]
        if info.colorProperties.count == 3 { videoSettings[AVVideoColorPropertiesKey] = info.colorProperties }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = info.transform
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(videoInput) else { throw MiradaError.outputUnwritable(output, "can't write \(codec.rawValue) video to .\(output.pathExtension)") }
        writer.add(videoInput)

        // Audio: compressed samples straight from the reader to the writer.
        var audio: (reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if options.includeAudio, let track = try await source.asset.loadTracks(withMediaType: .audio).first {
            let reader = try AVAssetReader(asset: source.asset)
            if let range { reader.timeRange = range }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(out)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audio = (reader, out, input)
            }
        }

        guard writer.startWriting() else {
            throw MiradaError.outputUnwritable(output, writer.error?.localizedDescription ?? "can't start writing")
        }
        let sessionStart = range?.start ?? .zero
        writer.startSession(atSourceTime: sessionStart)
        if let audio, !audio.reader.startReading() {
            throw MiradaError.inputUnreadable(input, audio.reader.error?.localizedDescription ?? "audio")
        }

        let clock = Stopwatch()
        let duration = (range?.duration ?? info.duration).seconds
        let box = WriterBox(writer: writer, video: videoInput, adaptor: adaptor, audio: audio)

        do {
            let counts = try await withThrowingTaskGroup(of: (Int, Int)?.self) { group in
                group.addTask {
                    var frames = 0, corrected = 0
                    for try await frame in source.frames() {
                        try Task.checkCancellation()
                        let result = await pipeline.process(frame)
                        try await box.appendVideo(result.output.pixelBuffer, at: frame.time)
                        frames += 1
                        if result.output.pixelBuffer !== frame.pixelBuffer { corrected += 1 }
                        if let progress, frames % 10 == 1 {
                            let done = max(0, (frame.time - sessionStart).seconds)
                            let rate = Double(frames) / max(clock.ms / 1000, 1e-3)
                            let remaining = max(0, duration - done) * fps / rate
                            progress(FileJobProgress(fraction: duration > 0 ? min(1, done / duration) : 0, frames: frames,
                                                     fps: rate, eta: frames > 30 ? remaining : nil))
                        }
                    }
                    box.video.markAsFinished()
                    return (frames, corrected)
                }
                if audio != nil {
                    group.addTask {
                        try await box.copyAudio()
                        return nil
                    }
                }
                var result = (0, 0)
                for try await r in group { if let r { result = r } }
                return result
            }
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw MiradaError.outputUnwritable(output, writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
            }
            let elapsed = clock.ms / 1000
            let mediaSeconds = Double(counts.0) / fps
            progress?(FileJobProgress(fraction: 1, frames: counts.0, fps: Double(counts.0) / max(elapsed, 1e-3), eta: 0))
            return FileJobReport(
                input: input.path, output: output.path, frames: counts.0, correctedFrames: counts.1,
                mediaSeconds: duration, elapsedSeconds: elapsed, speed: mediaSeconds / max(elapsed, 1e-3),
                codec: codec, audioCopied: audio != nil, hdrSource: info.isHDR,
                stages: Dictionary(uniqueKeysWithValues: pipeline.stats.summary().map { ($0.key.rawValue, $0.value) })
            )
        } catch {
            writer.cancelWriting()
            audio?.reader.cancelReading()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func timeRange(_ o: FileJobOptions) throws -> CMTimeRange? {
        guard o.start != nil || o.end != nil else { return nil }
        let start = o.start ?? 0
        if start < 0 { throw MiradaError.invalidArgument("--start must be >= 0") }
        if let end = o.end, end <= start { throw MiradaError.invalidArgument("--end must be after --start") }
        let s = CMTime(seconds: start, preferredTimescale: 600)
        let e = o.end.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity
        return CMTimeRange(start: s, end: e)
    }

    static func sourceCodec(_ asset: AVAsset) async throws -> VideoCodec {
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let desc = try await track.load(.formatDescriptions).first else { return .h264 }
        return CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_HEVC ? .hevc : .h264
    }
}

/// The writer side, shared by the two tasks. Each input is only touched by
/// its own task.
private final class WriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audio: (reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?

    init(writer: AVAssetWriter, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
         audio: (reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?) {
        self.writer = writer
        self.video = video
        self.adaptor = adaptor
        self.audio = audio
    }

    func waitReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw MiradaError.outputUnwritable(writer.outputURL, writer.error?.localizedDescription ?? "writer failed") }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000)
        }
    }

    func appendVideo(_ pb: CVPixelBuffer, at time: CMTime) async throws {
        try await waitReady(video)
        guard adaptor.append(pb, withPresentationTime: time) else {
            throw MiradaError.outputUnwritable(writer.outputURL, writer.error?.localizedDescription ?? "video append failed")
        }
    }

    func copyAudio() async throws {
        guard let audio else { return }
        while let sample = audio.output.copyNextSampleBuffer() {
            try await waitReady(audio.input)
            guard audio.input.append(sample) else {
                throw MiradaError.outputUnwritable(writer.outputURL, writer.error?.localizedDescription ?? "audio append failed")
            }
        }
        audio.input.markAsFinished()
    }
}
