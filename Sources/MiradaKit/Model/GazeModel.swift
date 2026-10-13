import CoreML
import Foundation

/// Which compiled FLX model runs, and where.
public enum ModelBackend: String, CaseIterable, Sendable, Codable {
    /// fp16 network on the Neural Engine (default, ~0.4 ms per frame on M2 Max).
    case ane
    /// fp32 network on the CPU (~2.4 ms), numerically exact to the TF original.
    case cpu
}

/// One eye's model input: the 64x48 RGB crop (HWC, [0,1]) and its six anchor
/// points as `x0, y0, …, x5, y5` in crop pixels.
public struct EyeInput: Sendable {
    public var rgb: [Float]
    public var anchors: [Float]

    public init(rgb: [Float], anchors: [Float]) {
        self.rgb = rgb
        self.anchors = anchors
    }

    public init(rgb: [Float], crop: EyeCrop) {
        self.init(rgb: rgb, anchors: crop.anchorPoints.flatMap { [Float($0.x), Float($0.y)] })
    }
}

/// One eye's model output, HWC at 64x48: `flow` is the tanh flow in the
/// sampler's normalized units, `light` the two softmax light weights
/// (image, white).
public struct EyeWarp: Sendable {
    public var flow: [Float]
    public var light: [Float]
}

/// The FLX gaze-warping network for both eyes, one CoreML call per frame.
public final class GazeModel: @unchecked Sendable {
    public let backend: ModelBackend
    private let model: MLModel
    private let inputs: MLDictionaryFeatureProvider
    private let leftImage, rightImage, leftAnchors, rightAnchors, angle: MLMultiArray
    private let lock = NSLock()

    static let h = EyeCrop.modelHeight, w = EyeCrop.modelWidth

    public init(backend: ModelBackend = .ane) throws {
        self.backend = backend
        let url = try Self.modelURL(backend)
        let config = MLModelConfiguration()
        config.computeUnits = backend == .ane ? .cpuAndNeuralEngine : .cpuOnly
        do {
            model = try MLModel(contentsOf: url, configuration: config)
            func array(_ shape: [Int]) throws -> MLMultiArray {
                try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
            }
            leftImage = try array([1, Self.h, Self.w, 3])
            rightImage = try array([1, Self.h, Self.w, 3])
            leftAnchors = try array([1, 12])
            rightAnchors = try array([1, 12])
            angle = try array([1, 2])
            inputs = try MLDictionaryFeatureProvider(dictionary: [
                "left_image": leftImage, "right_image": rightImage,
                "left_anchors": leftAnchors, "right_anchors": rightAnchors, "angle": angle,
            ])
        } catch {
            throw MiradaError.modelMissing(error.localizedDescription)
        }
    }

    /// Bundled compiled model. `MIRADA_MODEL_DIR` overrides the location (for
    /// a CLI installed away from its resource bundle).
    static func modelURL(_ backend: ModelBackend) throws -> URL {
        let name = backend == .ane ? "FLXFlow16.mlmodelc" : "FLXFlow32.mlmodelc"
        var candidates: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["MIRADA_MODEL_DIR"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        if let res = Bundle.module.resourceURL {
            candidates.append(res.appendingPathComponent("Resources").appendingPathComponent(name))
            candidates.append(res.appendingPathComponent(name))
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw MiradaError.modelMissing("\(name) not found (looked in \(candidates.map(\.path).joined(separator: ", ")))")
        }
        return url
    }

    public func predict(left: EyeInput, right: EyeInput, angle a: GazeAngle) throws -> (left: EyeWarp, right: EyeWarp) {
        try lock.withLock {
            Self.write(left.rgb, into: leftImage)
            Self.write(right.rgb, into: rightImage)
            Self.write(left.anchors, into: leftAnchors)
            Self.write(right.anchors, into: rightAnchors)
            Self.write([Float(a.vertical), Float(a.horizontal)], into: angle)
            let out: MLFeatureProvider
            do {
                out = try model.prediction(from: inputs)
            } catch {
                throw MiradaError.internalError("model prediction failed: \(error.localizedDescription)")
            }
            func read(_ name: String) throws -> [Float] {
                guard let m = out.featureValue(for: name)?.multiArrayValue else {
                    throw MiradaError.internalError("model output \(name) missing")
                }
                return Self.readHWC(m)
            }
            return (
                EyeWarp(flow: try read("left_flow"), light: try read("left_light")),
                EyeWarp(flow: try read("right_flow"), light: try read("right_light"))
            )
        }
    }

    static func write(_ values: [Float], into array: MLMultiArray) {
        precondition(values.count == array.count, "input size \(values.count) != \(array.count)")
        let p = array.dataPointer.assumingMemoryBound(to: Float.self)
        values.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: values.count) }
    }

    /// Reads a (1, H, W, C) output into a dense HWC array, honouring strides
    /// and fp16 outputs.
    static func readHWC(_ m: MLMultiArray) -> [Float] {
        let shape = m.shape.map(\.intValue), strides = m.strides.map(\.intValue)
        let hh = shape[1], ww = shape[2], cc = shape[3]
        var out = [Float](repeating: 0, count: hh * ww * cc)
        func fill<T>(_ type: T.Type, _ convert: (T) -> Float) {
            let p = m.dataPointer.assumingMemoryBound(to: T.self)
            for y in 0..<hh {
                for x in 0..<ww {
                    for c in 0..<cc {
                        out[(y * ww + x) * cc + c] = convert(p[y * strides[1] + x * strides[2] + c * strides[3]])
                    }
                }
            }
        }
        switch m.dataType {
        case .float16: fill(Float16.self) { Float($0) }
        case .double: fill(Double.self) { Float($0) }
        default: fill(Float.self) { $0 }
        }
        return out
    }
}

/// The FLX sampler and light correction on the CPU, float32, with the exact
/// semantics of upstream `transformation.py`: sample at
/// `0.5·(flow + linspace(-1,1) + 1)·size`, bilinear, and zero wherever the
/// sample falls outside `[0, W-1) × [0, H-1)`.
public enum EyeWarper {
    public static func apply(rgb: [Float], warp: EyeWarp) -> [Float] {
        let h = EyeCrop.modelHeight, w = EyeCrop.modelWidth
        var out = [Float](repeating: 0, count: h * w * 3)
        for y in 0..<h {
            let gy = Float(-1) + 2 * Float(y) / Float(h - 1)
            for x in 0..<w {
                let i = y * w + x
                let gx = Float(-1) + 2 * Float(x) / Float(w - 1)
                let sx = (warp.flow[i * 2] + gx + 1) * (0.5 * Float(w))
                let sy = (warp.flow[i * 2 + 1] + gy + 1) * (0.5 * Float(h))
                let wImg = warp.light[i * 2], wWhite = warp.light[i * 2 + 1]
                var px: (Float, Float, Float) = (0, 0, 0)
                if sx >= 0, sx < Float(w - 1), sy >= 0, sy < Float(h - 1) {
                    let x0 = Int(sx), y0 = Int(sy)
                    let fx = sx - Float(x0), fy = sy - Float(y0)
                    let a = (y0 * w + x0) * 3, b = a + 3, c = a + w * 3, d = c + 3
                    let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                    px = (rgb[a] * w00 + rgb[b] * w10 + rgb[c] * w01 + rgb[d] * w11,
                          rgb[a + 1] * w00 + rgb[b + 1] * w10 + rgb[c + 1] * w01 + rgb[d + 1] * w11,
                          rgb[a + 2] * w00 + rgb[b + 2] * w10 + rgb[c + 2] * w01 + rgb[d + 2] * w11)
                }
                out[i * 3] = px.0 * wImg + wWhite
                out[i * 3 + 1] = px.1 * wImg + wWhite
                out[i * 3 + 2] = px.2 * wImg + wWhite
            }
        }
        return out
    }
}
