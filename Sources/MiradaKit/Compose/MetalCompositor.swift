import CoreVideo
import Metal

/// One eye's correction to paint into a frame.
public struct WarpPatch: Sendable {
    public var crop: EyeCrop
    public var warp: EyeWarp
    /// 0 leaves the eye untouched, 1 applies the full correction.
    public var alpha: Float

    public init(crop: EyeCrop, warp: EyeWarp, alpha: Float) {
        self.crop = crop
        self.warp = warp
        self.alpha = alpha
    }
}

/// Paints corrected eyes into a copy of the frame on the GPU.
///
/// The model's flow is defined on the 64x48 crop, but it is applied to the
/// full-resolution frame: every output pixel inside the crop looks up the
/// flow at its crop position and samples the original frame where the TF
/// sampler would have sampled the crop. Eyes keep their native detail instead
/// of being upscaled from 64x48. A feathered mask leaves the crop's outer 3
/// model pixels original (the model's loss ignored them) and blends in over
/// the next few.
public final class MetalCompositor: @unchecked Sendable {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let warpTextures: [MTLTexture]
    private let warpFormat: MTLPixelFormat
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private let lock = NSLock()

    struct Params {
        var bufToUp0: SIMD4<Float>
        var bufToUp1: SIMD4<Float>
        var upToBuf0: SIMD4<Float>
        var upToBuf1: SIMD4<Float>
        var crop: SIMD4<Float>
        var origin: SIMD2<UInt32>
        var alpha: Float
        var pad: Float = 0
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw MiradaError.internalError("no Metal device")
        }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let fn = library.makeFunction(name: "warpEye") else { throw MiradaError.internalError("warpEye missing") }
            pipeline = try device.makeComputePipelineState(function: fn)
        } catch let e as MiradaError {
            throw e
        } catch {
            throw MiradaError.internalError("Metal shader: \(error.localizedDescription)")
        }
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &c) == kCVReturnSuccess, let c else {
            throw MiradaError.internalError("CVMetalTextureCache")
        }
        cache = c
        // Bilinear filtering of float32 textures needs Apple7+ (M1 and later); fall back to half floats.
        warpFormat = device.supports32BitFloatFiltering ? .rgba32Float : .rgba16Float
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: warpFormat, width: EyeCrop.modelWidth, height: EyeCrop.modelHeight, mipmapped: false)
        desc.usage = .shaderRead
        warpTextures = try (0..<2).map { _ in
            guard let t = device.makeTexture(descriptor: desc) else { throw MiradaError.internalError("warp texture") }
            return t
        }
    }

    /// A pooled BGRA buffer of the given size.
    public func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if pool == nil || poolSize != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
            pool = p
            poolSize = (width, height)
        }
        var pb: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else {
            throw MiradaError.internalError("pixel buffer pool exhausted")
        }
        return pb
    }

    private func texture(_ pb: CVPixelBuffer) throws -> MTLTexture {
        var t: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                               CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
        guard status == kCVReturnSuccess, let t, let tex = CVMetalTextureGetTexture(t) else {
            throw MiradaError.internalError("can't wrap pixel buffer as a texture (\(status))")
        }
        return tex
    }

    /// Returns a new buffer: the frame with the patches painted in.
    public func compose(_ frame: Frame, patches: [WarpPatch]) throws -> CVPixelBuffer {
        try lock.withLock {
            let src = frame.pixelBuffer
            let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
            let out = try makeBuffer(width: w, height: h)
            CVBufferPropagateAttachments(src, out)
            let srcTex = try texture(src), dstTex = try texture(out)
            guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else {
                throw MiradaError.internalError("Metal command buffer")
            }
            blit.copy(from: srcTex, to: dstTex)
            blit.endEncoding()

            let map = frame.mapping
            let up2buf = map.uprightToBuffer
            let buf2up = Self.invert(up2buf)
            for (i, patch) in patches.prefix(2).enumerated() where patch.alpha > 0 {
                let tex = warpTextures[i]
                var packed = [Float](repeating: 0, count: EyeCrop.modelWidth * EyeCrop.modelHeight * 4)
                for k in 0..<(EyeCrop.modelWidth * EyeCrop.modelHeight) {
                    packed[k * 4] = patch.warp.flow[k * 2]
                    packed[k * 4 + 1] = patch.warp.flow[k * 2 + 1]
                    packed[k * 4 + 2] = patch.warp.light[k * 2]
                    packed[k * 4 + 3] = patch.warp.light[k * 2 + 1]
                }
                let region = MTLRegionMake2D(0, 0, EyeCrop.modelWidth, EyeCrop.modelHeight)
                if warpFormat == .rgba32Float {
                    packed.withUnsafeBytes { tex.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: EyeCrop.modelWidth * 16) }
                } else {
                    let half = packed.map { Float16($0) }
                    half.withUnsafeBytes { tex.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: EyeCrop.modelWidth * 8) }
                }
                let c = patch.crop
                let box = Self.bufferBox(map: map, crop: c, width: w, height: h)
                guard box.width > 0, box.height > 0 else { continue }
                var params = Params(
                    bufToUp0: SIMD4(buf2up[0], buf2up[1], buf2up[2], 0), bufToUp1: SIMD4(buf2up[3], buf2up[4], buf2up[5], 0),
                    upToBuf0: SIMD4(up2buf[0], up2buf[1], up2buf[2], 0), upToBuf1: SIMD4(up2buf[3], up2buf[4], up2buf[5], 0),
                    crop: SIMD4(Float(c.left), Float(c.top), Float(c.width), Float(c.height)),
                    origin: SIMD2(UInt32(box.x), UInt32(box.y)), alpha: min(1, patch.alpha)
                )
                guard let enc = cmd.makeComputeCommandEncoder() else { throw MiradaError.internalError("Metal encoder") }
                enc.setComputePipelineState(pipeline)
                enc.setTexture(srcTex, index: 0)
                enc.setTexture(dstTex, index: 1)
                enc.setTexture(tex, index: 2)
                enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
                let tg = MTLSize(width: 16, height: 16, depth: 1)
                enc.dispatchThreads(MTLSize(width: box.width, height: box.height, depth: 1), threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
            cmd.commit()
            cmd.waitUntilCompleted()
            if let error = cmd.error { throw MiradaError.internalError("Metal: \(error.localizedDescription)") }
            return out
        }
    }

    /// Buffer-space pixel box covering an upright crop rectangle.
    static func bufferBox(map: UprightMapping, crop c: EyeCrop, width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let corners = [CGPoint(x: c.left, y: c.top), CGPoint(x: c.left + c.width, y: c.top),
                       CGPoint(x: c.left, y: c.top + c.height), CGPoint(x: c.left + c.width, y: c.top + c.height)].map(map.bufferPoint)
        let x0 = max(0, Int(floor(corners.map(\.x).min()!)) - 1), y0 = max(0, Int(floor(corners.map(\.y).min()!)) - 1)
        let x1 = min(width, Int(ceil(corners.map(\.x).max()!)) + 1), y1 = min(height, Int(ceil(corners.map(\.y).max()!)) + 1)
        return (x0, y0, max(0, x1 - x0), max(0, y1 - y0))
    }

    /// Inverse of a row-major 2x3 affine `[a, b, tx, c, d, ty]`.
    static func invert(_ m: [Float]) -> [Float] {
        let det = m[0] * m[4] - m[1] * m[3]
        let a = m[4] / det, b = -m[1] / det, c = -m[3] / det, d = m[0] / det
        return [a, b, -(a * m[2] + b * m[5]), c, d, -(c * m[2] + d * m[5])]
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float4 bufToUp0;
        float4 bufToUp1;
        float4 upToBuf0;
        float4 upToBuf1;
        float4 crop;      // left, top, width, height in upright pixels
        uint2 origin;     // buffer-space origin of this dispatch
        float alpha;
        float pad;
    };

    kernel void warpEye(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        texture2d<float, access::sample> warp [[texture(2)]],
                        constant Params& p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        uint2 bp = gid + p.origin;
        if (bp.x >= dst.get_width() || bp.y >= dst.get_height()) return;
        constexpr sampler px(coord::pixel, address::clamp_to_edge, filter::linear);
        constexpr sampler nrm(coord::normalized, address::clamp_to_edge, filter::linear);

        float3 b = float3(float2(bp) + 0.5, 1.0);
        float2 up = float2(dot(p.bufToUp0.xyz, b), dot(p.bufToUp1.xyz, b));
        float2 local = (up - p.crop.xy) / p.crop.zw;
        if (any(local < 0.0) || any(local > 1.0)) return;

        // Position in the model's 64x48 pixel-index space.
        float2 m = local * float2(64.0, 48.0) - 0.5;
        float2 edge = min(m, float2(63.0, 47.0) - m);
        float a = smoothstep(3.0, 9.0, edge.x) * smoothstep(3.0, 8.0, edge.y) * p.alpha;
        if (a <= 0.0) return;

        // flow.xy, light (image weight, white weight)
        float4 fl = warp.sample(nrm, local);
        float2 g = -1.0 + 2.0 * m / float2(63.0, 47.0);
        float2 s = (fl.xy + g + 1.0) * float2(32.0, 24.0);
        float3 cropPos = float3((s + 0.5) / float2(64.0, 48.0) * p.crop.zw + p.crop.xy, 1.0);
        float2 sb = float2(dot(p.upToBuf0.xyz, cropPos), dot(p.upToBuf1.xyz, cropPos));

        float3 orig = src.sample(px, float2(bp) + 0.5).rgb;
        float3 corrected = src.sample(px, sb).rgb * fl.z + fl.w;
        dst.write(float4(mix(orig, saturate(corrected), a), 1.0), bp);
    }
    """
}
