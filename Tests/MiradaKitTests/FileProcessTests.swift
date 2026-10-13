@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import MiradaKit

/// End-to-end `mirada process` behaviour on the fixture clips.
@Suite(.serialized) struct FileProcessTests {
    static let clip = TestImages.fixtures.appendingPathComponent("clip.mp4")
    static let rotated = TestImages.fixtures.appendingPathComponent("clip_rot90.mp4")

    static func temp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mirada-test-\(UUID().uuidString).\(ext)")
    }

    static func run(_ input: URL, _ output: URL, _ options: FileJobOptions = FileJobOptions()) async throws -> FileJobReport {
        let pipeline = try GazePipeline(settings: MiradaSettings())
        return try await FileJob.run(input: input, output: output, options: options, pipeline: pipeline)
    }

    struct VideoFacts {
        var frames = 0
        var size = CGSize.zero
        var fps: Float = 0
        var duration = 0.0
        var transform = CGAffineTransform.identity
        var audioPackets = 0
        var audioDigest = ""
    }

    static func facts(_ url: URL) async throws -> VideoFacts {
        let asset = AVURLAsset(url: url)
        var f = VideoFacts()
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        (f.size, f.fps, f.transform) = try await video.load(.naturalSize, .nominalFrameRate, .preferredTransform)
        f.duration = try await asset.load(.duration).seconds
        let r = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        r.add(vo)
        var ao: AVAssetReaderTrackOutput?
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            ao = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            r.add(ao!)
        }
        r.startReading()
        while let s = vo.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(s) > 0 { f.frames += 1 } }
        var hash = SHA256()
        while let ao, let s = ao.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(s) else { continue }
            f.audioPackets += CMSampleBufferGetNumSamples(s)
            var data = Data(count: CMBlockBufferGetDataLength(block))
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            hash.update(data: data)
        }
        f.audioDigest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return f
    }

    @Test func keepsTimingSizeAndAudio() async throws {
        let out = Self.temp("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let report = try await Self.run(Self.clip, out)
        let a = try await Self.facts(Self.clip), b = try await Self.facts(out)
        #expect(report.frames == 300)
        #expect(report.correctedFrames > 0)
        #expect(b.frames == a.frames)
        #expect(b.size == a.size)
        #expect(abs(b.fps - a.fps) < 0.01)
        #expect(abs(b.duration - a.duration) < 1.0 / 30)
        #expect(b.audioPackets == a.audioPackets)
        #expect(b.audioDigest == a.audioDigest, "audio must be copied bit for bit")
        #expect(report.audioCopied)
    }

    @Test func testNoAudioTrack() async throws {
        let out = Self.temp("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await Self.run(Self.clip, out, FileJobOptions(end: 1, includeAudio: false))
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        #expect(tracks.isEmpty)
    }

    @Test func testRotationPreserved() async throws {
        let out = Self.temp("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let report = try await Self.run(Self.rotated, out, FileJobOptions(codec: .hevc))
        let a = try await Self.facts(Self.rotated), b = try await Self.facts(out)
        #expect(b.transform == a.transform)
        #expect(b.size == a.size)
        #expect(report.codec == .hevc)
        #expect(report.correctedFrames > 0, "faces in sideways-stored frames must still be found")
    }

    @Test func trimsToTimeRange() async throws {
        let out = Self.temp("mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await Self.run(Self.clip, out, FileJobOptions(start: 2, end: 5))
        let b = try await Self.facts(out)
        #expect(abs(b.duration - 3) <= 1.5 / 30)
    }

    @Test func cancellationRemovesPartialOutput() async throws {
        let out = Self.temp("mp4")
        let job = Task { try await Self.run(Self.clip, out) }
        try await Task.sleep(nanoseconds: 400_000_000)
        job.cancel()
        await #expect(throws: (any Error).self) { _ = try await job.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func rejectsBadTimeRange() async throws {
        await #expect(throws: MiradaError.invalidArgument("--end must be after --start")) {
            _ = try await Self.run(Self.clip, Self.temp("mp4"), FileJobOptions(start: 4, end: 2))
        }
    }
}
