import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MiradaKit

@Suite(.serialized) struct PipelineTests {
    static let clip = TestImages.fixtures.appendingPathComponent("clip.mp4")

    /// Decoded frame of the fixture clip nearest to `seconds`.
    static func frame(at seconds: Double, in url: URL = clip) async throws -> Frame {
        let source = try await FileSource(url: url)
        for try await f in source.frames() where f.time.seconds >= seconds - 0.5 / 30 {
            return f
        }
        throw MiradaError.internalError("no frame at \(seconds)")
    }

    @Test func noFacePassesTheSameBuffer() async throws {
        let blank = try TestImages.makeBGRA(width: 320, height: 240)
        TestImages.fill(blank) { _, _ in (r: 90, g: 120, b: 140) }
        let pipeline = try GazePipeline(settings: MiradaSettings())
        let out = await pipeline.process(Frame(pixelBuffer: blank, time: CMTime(value: 1, timescale: 30)))
        #expect(out.face == .noFace)
        #expect(out.output.pixelBuffer === blank)
    }

    @Test func zeroStrengthPassesTheSameBuffer() async throws {
        let f = try await Self.frame(at: 6)
        var s = MiradaSettings()
        s.strength = 0
        let pipeline = try GazePipeline(settings: s)
        let out = await pipeline.processStill(f)
        #expect(out.face == .tracking)
        #expect(out.output.pixelBuffer === f.pixelBuffer)
    }

    @Test func disabledPassesTheSameBuffer() async throws {
        let f = try await Self.frame(at: 6)
        var s = MiradaSettings()
        s.enabled = false
        let out = await (try GazePipeline(settings: s)).processStill(f)
        #expect(out.output.pixelBuffer === f.pixelBuffer)
    }

    @Test func correctsOnlyInsideEyeCrops() async throws {
        let f = try await Self.frame(at: 6)
        let pipeline = try GazePipeline(settings: MiradaSettings())
        let out = await pipeline.processStill(f)
        #expect(out.face == .tracking)
        let face = try #require(out.landmarks)
        let crops = [face.leftEye, face.rightEye].compactMap { EyeCrop.make($0, frameWidth: f.width, frameHeight: f.height) }
        #expect(crops.count == 2)
        func inside(_ x: Int, _ y: Int) -> Bool {
            crops.contains { x >= $0.left - 1 && x <= $0.left + $0.width && y >= $0.top - 1 && y <= $0.top + $0.height }
        }
        var changedInside = 0, changedOutside = 0
        for y in stride(from: 0, to: f.height, by: 2) {
            for x in stride(from: 0, to: f.width, by: 2) where TestImages.read(out.output.pixelBuffer, x: x, y: y) != TestImages.read(f.pixelBuffer, x: x, y: y) {
                if inside(x, y) { changedInside += 1 } else { changedOutside += 1 }
            }
        }
        #expect(changedOutside == 0)
        #expect(changedInside > 50)
    }

    @Test func videoRampsInAndStaysStable() async throws {
        // Run 2 s of the clip through the pipeline as video: the fade starts at
        // zero, ramps up, and the stage stats fill in.
        let source = try await FileSource(url: Self.clip, timeRange: CMTimeRange(start: CMTime(seconds: 5, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600)))
        let pipeline = try GazePipeline(settings: MiradaSettings())
        var fades: [Double] = []
        for try await f in source.frames() {
            fades.append(await pipeline.process(f).fade)
        }
        #expect(fades.count >= 59)
        #expect(fades.first! < 0.5)
        #expect(fades.suffix(30).allSatisfy { $0 > 0.9 })
        let failures = await pipeline.failures
        #expect(failures == 0)
        #expect(pipeline.stats.summary()[.model] != nil)
    }
}

@Suite(.serialized) struct FaceTrackerTests {
    @Test func resetAlwaysDetectsNextFrame() async throws {
        let face = try await PipelineTests.frame(at: 6)
        let blank = try TestImages.makeBGRA(width: 320, height: 240)
        TestImages.fill(blank) { _, _ in (r: 40, g: 40, b: 40) }
        let tracker = FaceTracker()
        #expect(try tracker.detect(Frame(pixelBuffer: blank, time: .zero)) == nil)   // no face: idle throttling starts
        tracker.reset()
        #expect(try tracker.detect(face) != nil)                                        // reset: detect at once
    }

    @Test func idleThrottleLooksEveryThirdFrame() throws {
        let blank = try TestImages.makeBGRA(width: 320, height: 240)
        TestImages.fill(blank) { _, _ in (r: 40, g: 40, b: 40) }
        let tracker = FaceTracker()
        for _ in 0..<9 { _ = try tracker.detect(Frame(pixelBuffer: blank, time: .zero)) }
        #expect(tracker.detections == 3)
    }

    @Test func tracksBetweenDetections() async throws {
        let source = try await FileSource(url: PipelineTests.clip, timeRange: CMTimeRange(start: CMTime(seconds: 5, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600)))
        let tracker = FaceTracker(redetectInterval: 6)
        var found = 0, frames = 0
        for try await f in source.frames() {
            frames += 1
            if try tracker.detect(f) != nil { found += 1 }
        }
        #expect(found == frames)
        #expect(tracker.detections <= frames / 6 + 2)
    }
}

@Suite(.serialized) struct DebugOverlayTests {
    @Test func drawsOnACopyNeverTheInput() async throws {
        let blank = try TestImages.makeBGRA(width: 320, height: 240)
        TestImages.fill(blank) { _, _ in (r: 90, g: 120, b: 140) }
        var s = MiradaSettings()
        s.debugOverlay = true
        let out = await (try GazePipeline(settings: s)).process(Frame(pixelBuffer: blank, time: CMTime(value: 1, timescale: 30)))
        #expect(out.output.pixelBuffer !== blank)
        #expect(TestImages.read(blank, x: 20, y: 20) == (90, 120, 140))      // input untouched
        #expect(TestImages.read(out.output.pixelBuffer, x: 20, y: 20) != (90, 120, 140))   // readout panel drawn
        #expect(TestImages.read(out.output.pixelBuffer, x: 300, y: 230) == (90, 120, 140)) // rest unchanged
    }

    @Test func overlayOnCorrectedFrame() async throws {
        let f = try await PipelineTests.frame(at: 6)
        var s = MiradaSettings()
        s.debugOverlay = true
        let out = await (try GazePipeline(settings: s)).processStill(f)
        #expect(out.face == .tracking)
        #expect(out.output.pixelBuffer !== f.pixelBuffer)
    }
}
