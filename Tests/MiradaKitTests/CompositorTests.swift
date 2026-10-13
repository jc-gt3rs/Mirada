import CoreGraphics
import CoreMedia
import CoreVideo
import Testing
@testable import MiradaKit

@Suite struct CompositorTests {
    /// A smooth textured frame: values vary slowly so bilinear sampling at
    /// 64x48 and at full resolution agree.
    static func frame(width: Int, height: Int) throws -> CVPixelBuffer {
        let pb = try TestImages.makeBGRA(width: width, height: height)
        TestImages.fill(pb) { x, y in
            let fx = Double(x), fy = Double(y)
            return (r: UInt8(128 + 100 * sin(fx / 9)), g: UInt8(128 + 100 * cos(fy / 7)), b: UInt8(128 + 60 * sin((fx + fy) / 13)))
        }
        return pb
    }

    /// A gentle swirl flow (±0.04 normalized, about ±1.3 model px) and a slight lift toward white.
    static func warp() -> EyeWarp {
        var flow = [Float](), light = [Float]()
        for y in 0..<48 {
            for x in 0..<64 {
                flow += [0.04 * Float(sin(Double(y) / 8)), -0.03 * Float(cos(Double(x) / 10))]
                light += [0.92, 0.08]
            }
        }
        return EyeWarp(flow: flow, light: light)
    }

    static func crop(left: Int, top: Int) -> EyeCrop {
        EyeCrop(top: top, left: left, height: 48, width: 64, anchorPoints: Array(repeating: (x: 0, y: 0), count: 6))
    }

    @Test func zeroAlphaIsBitExact() throws {
        let src = try Self.frame(width: 320, height: 240)
        let c = try MetalCompositor()
        let out = try c.compose(Frame(pixelBuffer: src, time: .zero), patches: [WarpPatch(crop: Self.crop(left: 100, top: 80), warp: Self.warp(), alpha: 0)])
        for (x, y) in [(0, 0), (130, 100), (319, 239), (163, 127)] {
            #expect(TestImages.read(out, x: x, y: y) == TestImages.read(src, x: x, y: y))
        }
    }

    /// With a crop exactly 64x48 at full resolution, the GPU path must match
    /// the TF-exact CPU warper inside the fully-corrected region.
    @Test func matchesCPUWarperAtModelResolution() throws {
        let src = try Self.frame(width: 320, height: 240)
        let crop = Self.crop(left: 100, top: 80)
        let warp = Self.warp()
        let out = try MetalCompositor().compose(Frame(pixelBuffer: src, time: .zero), patches: [WarpPatch(crop: crop, warp: warp, alpha: 1)])
        let rgb = EyeImage.sampleRGB(src, mapping: UprightMapping(bufferWidth: 320, bufferHeight: 240, orientation: .up), crop: crop)
        let cpu = EyeWarper.apply(rgb: rgb, warp: warp)
        var worst: Float = 0
        for y in 9..<39 {
            for x in 10..<54 {
                let g = TestImages.read(out, x: crop.left + x, y: crop.top + y)
                let o = (y * 64 + x) * 3
                worst = max(worst, abs(Float(g.0) - cpu[o] * 255), abs(Float(g.1) - cpu[o + 1] * 255), abs(Float(g.2) - cpu[o + 2] * 255))
            }
        }
        #expect(worst <= 1.5, "worst \(worst) levels")
    }

    @Test func rotatedFrameMatchesUpright() throws {
        let upright = try Self.frame(width: 320, height: 240)
        let stored = try EyeCropTests.rotateCCW(upright)
        let crop = Self.crop(left: 100, top: 80)
        let c = try MetalCompositor()
        let a = try c.compose(Frame(pixelBuffer: upright, time: .zero), patches: [WarpPatch(crop: crop, warp: Self.warp(), alpha: 1)])
        let b = try c.compose(Frame(pixelBuffer: stored, time: .zero, orientation: .right), patches: [WarpPatch(crop: crop, warp: Self.warp(), alpha: 1)])
        var worst = 0
        for y in 80..<128 {
            for x in 100..<164 {
                let p = TestImages.read(a, x: x, y: y)
                let q = TestImages.read(b, x: y, y: 319 - x)
                worst = max(worst, abs(Int(p.0) - Int(q.0)), abs(Int(p.1) - Int(q.1)), abs(Int(p.2) - Int(q.2)))
            }
        }
        #expect(worst <= 1)
    }

    @Test func oddSize() throws {
        let src = try Self.frame(width: 641, height: 481)
        let out = try MetalCompositor().compose(Frame(pixelBuffer: src, time: .zero), patches: [WarpPatch(crop: Self.crop(left: 577, top: 433), warp: Self.warp(), alpha: 1)])
        #expect(CVPixelBufferGetWidth(out) == 641)
        #expect(CVPixelBufferGetHeight(out) == 481)
        #expect(TestImages.read(out, x: 0, y: 0) == TestImages.read(src, x: 0, y: 0))
    }
}
