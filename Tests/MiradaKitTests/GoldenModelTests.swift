import Foundation
import Testing
@testable import MiradaKit

/// The Swift model path (CoreML network + Swift sampler) against outputs of
/// the ORIGINAL TensorFlow graph (tools/convert_flx.py golden) on real eye
/// crops from the fixture clip.
@Suite struct GoldenModelTests {
    struct Manifest: Decodable {
        struct Eye: Decodable { let anchorPoints: [[Int]] }
        let left: Eye
        let right: Eye
    }

    struct Angles: Decodable { let angles: [[Double]]; let cases: [String] }

    static let dir = TestImages.fixtures.appendingPathComponent("golden")

    static func floats(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Returns (worst over whole crop, worst inside the composited region, mean).
    static func errors(_ backend: ModelBackend) throws -> (Float, Float, Float) {
        let model = try GazeModel(backend: backend)
        let spec = try JSONDecoder().decode(Angles.self, from: Data(contentsOf: dir.appendingPathComponent("angles.json")))
        var worst: Float = 0, worstInside: Float = 0, sum: Float = 0, n = 0
        for name in spec.cases {
            let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("\(name).json")))
            let inputs = [
                "left": EyeInput(rgb: try floats("\(name)_left_rgb.bin"), anchors: m.left.anchorPoints.flatMap { $0.map(Float.init) }),
                "right": EyeInput(rgb: try floats("\(name)_right_rgb.bin"), anchors: m.right.anchorPoints.flatMap { $0.map(Float.init) }),
            ]
            for (k, a) in spec.angles.enumerated() {
                let warps = try model.predict(left: inputs["left"]!, right: inputs["right"]!, angle: GazeAngle(vertical: a[0], horizontal: a[1]))
                for (side, warp) in [("left", warps.left), ("right", warps.right)] {
                    let got = EyeWarper.apply(rgb: inputs[side]!.rgb, warp: warp)
                    let want = try floats("\(name)_\(side)_a\(k)_out.bin")
                    for y in 0..<48 {
                        for x in 0..<64 {
                            for c in 0..<3 {
                                let e = abs(got[(y * 64 + x) * 3 + c] - want[(y * 64 + x) * 3 + c])
                                worst = max(worst, e)
                                if (3..<45).contains(y), (4..<60).contains(x) { worstInside = max(worstInside, e) }
                                sum += e
                                n += 1
                            }
                        }
                    }
                }
            }
        }
        return (worst, worstInside, sum / Float(n))
    }

    @Test func cpuBackendIsExact() throws {
        let (worst, _, mean) = try Self.errors(.cpu)
        #expect(worst < 2e-5, "worst \(worst)")
        #expect(mean < 1e-6, "mean \(mean)")
    }

    /// fp16 on the Neural Engine: within 2/255 where the compositor uses the
    /// output. Measured 1.42/255 worst, 4.4e-4 mean (DECISIONS.md, step 4).
    @Test func neuralEngineBackendIsWithinTolerance() throws {
        let (_, worstInside, mean) = try Self.errors(.ane)
        #expect(worstInside < 2.0 / 255, "worst inside \(worstInside * 255)/255")
        #expect(mean < 1e-3, "mean \(mean)")
    }
}
