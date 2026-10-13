import CoreGraphics

/// The eye region the model sees, computed exactly as the FLX training data
/// was (upstream `generate_training_inputs_from_raw_dataset.ipynb`): a box
/// 1.5 eye-lengths wide and 1.125 tall, 7/12 of it above the corner midpoint,
/// bounds rounded with +0.5, anchor origin truncated.
public struct EyeCrop: Sendable, Equatable {
    public static let modelWidth = 64
    public static let modelHeight = 48
    public static let anchorChannels = 12

    /// Crop bounds in upright pixel indices: rows `top ..< top+height`, cols `left ..< left+width`.
    public let top: Int
    public let left: Int
    public let height: Int
    public let width: Int
    /// Integer anchor positions in the 64x48 crop, training order.
    public let anchorPoints: [(x: Int, y: Int)]

    /// Anchor points as `[[x, y]]`, for comparisons and JSON.
    public var anchorList: [[Int]] { anchorPoints.map { [$0.x, $0.y] } }

    public static func == (a: EyeCrop, b: EyeCrop) -> Bool {
        a.top == b.top && a.left == b.left && a.height == b.height && a.width == b.width && a.anchorList == b.anchorList
    }

    /// Returns nil when the box falls even partly outside the frame or is too
    /// small to carry an eye (the pipeline then leaves that eye untouched).
    public static func make(_ eye: EyePoints, frameWidth: Int, frameHeight: Int) -> EyeCrop? {
        let a = eye.outer, b = eye.inner
        let cx = Double(a.x + b.x) * 0.5
        let cy = Double(a.y + b.y) * 0.5
        let eyeLen = abs(Double(a.x - b.x))
        let halfW = eyeLen * 3 / 4
        let boxH = 1.5 * halfW
        let up = boxH * 7 / 12
        let low = boxH * 5 / 12

        let top = pyInt(cy - up + 0.5), bottom = pyInt(cy + low + 0.5)
        let left = pyInt(cx - halfW + 0.5), right = pyInt(cx + halfW + 0.5)
        guard top >= 0, left >= 0, bottom <= frameHeight, right <= frameWidth else { return nil }
        let height = bottom - top, width = right - left
        guard width >= 8, height >= 6 else { return nil }

        let ltY = pyInt(cy - up), ltX = pyInt(cx - halfW)
        let sx = Double(modelWidth) / Double(width)
        let sy = Double(modelHeight) / Double(height)
        let anchors = eye.ordered.map { p in
            (x: pyInt((Double(p.x) - Double(ltX)) * sx + 0.5), y: pyInt((Double(p.y) - Double(ltY)) * sy + 0.5))
        }
        return EyeCrop(top: top, left: left, height: height, width: width, anchorPoints: anchors)
    }

    /// The 12-channel anchor map, HWC float32: channel 2i is `col - x_i`,
    /// channel 2i+1 is `row - y_i`.
    public var anchorMap: [Float] {
        var out = [Float](repeating: 0, count: Self.modelHeight * Self.modelWidth * Self.anchorChannels)
        for row in 0..<Self.modelHeight {
            for col in 0..<Self.modelWidth {
                let base = (row * Self.modelWidth + col) * Self.anchorChannels
                for (i, p) in anchorPoints.enumerated() {
                    out[base + 2 * i] = Float(col - p.x)
                    out[base + 2 * i + 1] = Float(row - p.y)
                }
            }
        }
        return out
    }

    /// Python's `int()`: truncation toward zero.
    static func pyInt(_ v: Double) -> Int { Int(v.rounded(.towardZero)) }
}
