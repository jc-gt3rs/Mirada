import CoreGraphics
import CoreVideo

/// Reads eye crops out of BGRA frames as the model's RGB input.
public enum EyeImage {
    /// Resizes the crop to 64x48 with `cv2.resize(INTER_LINEAR)` semantics
    /// (half-pixel centres, edge replicate inside the crop) and returns RGB
    /// floats in [0,1], HWC. Coordinates go through `mapping`, so rotated
    /// file frames are sampled upright.
    public static func sampleRGB(_ buffer: CVPixelBuffer, mapping: UprightMapping, crop: EyeCrop) -> [Float] {
        let w = EyeCrop.modelWidth, h = EyeCrop.modelHeight
        var out = [Float](repeating: 0, count: w * h * 3)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return out }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        let m = mapping.uprightToBuffer

        let scaleX = Double(crop.width) / Double(w)
        let scaleY = Double(crop.height) / Double(h)
        let maxX = Double(crop.width - 1), maxY = Double(crop.height - 1)
        let inv: Float = 1 / 255

        for row in 0..<h {
            let sy = min(max((Double(row) + 0.5) * scaleY - 0.5, 0), maxY)
            for col in 0..<w {
                let sx = min(max((Double(col) + 0.5) * scaleX - 0.5, 0), maxX)
                // Upright pixel-centre position -> continuous -> buffer continuous -> buffer index space.
                let ux = Float(Double(crop.left) + sx + 0.5), uy = Float(Double(crop.top) + sy + 0.5)
                let bx = m[0] * ux + m[1] * uy + m[2] - 0.5
                let by = m[3] * ux + m[4] * uy + m[5] - 0.5
                let rgb = bilinearBGRA(base, stride: stride, width: bw, height: bh, x: bx, y: by)
                let o = (row * w + col) * 3
                out[o] = rgb.r * inv
                out[o + 1] = rgb.g * inv
                out[o + 2] = rgb.b * inv
            }
        }
        return out
    }

    @inline(__always)
    static func bilinearBGRA(_ p: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, x: Float, y: Float) -> (r: Float, g: Float, b: Float) {
        let xc = min(max(x, 0), Float(width - 1)), yc = min(max(y, 0), Float(height - 1))
        let x0 = Int(xc), y0 = Int(yc)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = xc - Float(x0), fy = yc - Float(y0)
        func px(_ xi: Int, _ yi: Int) -> (Float, Float, Float) {
            let q = p + yi * stride + xi * 4
            return (Float(q[2]), Float(q[1]), Float(q[0]))
        }
        let a = px(x0, y0), b = px(x1, y0), c = px(x0, y1), d = px(x1, y1)
        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
        return (
            a.0 * w00 + b.0 * w10 + c.0 * w01 + d.0 * w11,
            a.1 * w00 + b.1 * w10 + c.1 * w01 + d.1 * w11,
            a.2 * w00 + b.2 * w10 + c.2 * w01 + d.2 * w11
        )
    }
}
