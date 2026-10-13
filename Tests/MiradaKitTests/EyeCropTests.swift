import CoreGraphics
import CoreVideo
import Testing
@testable import MiradaKit

/// Expected values come from `tools/reference_crop.py`, which uses the FLX
/// training notebook's math and OpenCV's resize.
@Suite struct EyeCropTests {
    static let rightEye = EyePoints(ordered: [
        CGPoint(x: 62.0, y: 80.0), CGPoint(x: 70.0, y: 74.6), CGPoint(x: 81.3, y: 73.0),
        CGPoint(x: 90.0, y: 78.0), CGPoint(x: 81.0, y: 82.2), CGPoint(x: 70.4, y: 82.9),
    ])
    static let leftEye = EyePoints(ordered: [
        CGPoint(x: 151.7, y: 77.2), CGPoint(x: 143.0, y: 72.4), CGPoint(x: 131.0, y: 72.0),
        CGPoint(x: 122.6, y: 77.8), CGPoint(x: 131.5, y: 81.0), CGPoint(x: 143.2, y: 81.4),
    ])

    @Test func boxAndAnchorsMatchTrainingMath() throws {
        let r = try #require(EyeCrop.make(Self.rightEye, frameWidth: 200, frameHeight: 150))
        let rBox: [Int] = [r.top, r.left, r.height, r.width]
        #expect(rBox == [61, 55, 31, 42])
        #expect(r.anchorList == [[11, 31], [23, 23], [40, 20], [53, 28], [40, 34], [23, 35]])

        let l = try #require(EyeCrop.make(Self.leftEye, frameWidth: 200, frameHeight: 150))
        let lBox: [Int] = [l.top, l.left, l.height, l.width]
        #expect(lBox == [58, 115, 33, 44])
        #expect(l.anchorList == [[53, 28], [41, 21], [23, 20], [11, 29], [24, 33], [41, 34]])
    }

    @Test func anchorMapChannels() throws {
        let r = try #require(EyeCrop.make(Self.rightEye, frameWidth: 200, frameHeight: 150))
        let map = r.anchorMap
        #expect(map.count == 48 * 64 * 12)
        // Pixel (row 5, col 7), point 2 at (40, 20): channels (7-40, 5-20).
        let base = (5 * 64 + 7) * 12
        #expect(map[base + 4] == -33)
        #expect(map[base + 5] == -15)
    }

    @Test func cropOutsideFrameReturnsNil() {
        let shifted = Self.rightEye.map { CGPoint(x: $0.x - 60, y: $0.y) }
        #expect(EyeCrop.make(shifted, frameWidth: 200, frameHeight: 150) == nil)
        let low = Self.leftEye.map { CGPoint(x: $0.x, y: $0.y + 66) }
        #expect(EyeCrop.make(low, frameWidth: 200, frameHeight: 150) == nil)
    }

    @Test func resizedPixelsMatchOpenCV() throws {
        let buffer = try Self.syntheticBuffer(width: 200, height: 150)
        let mapping = UprightMapping(bufferWidth: 200, bufferHeight: 150, orientation: .up)
        let expected: [String: [(Int, Int, [Float])]] = [
            "right": [(0, 0, [56, 13, 14]), (10, 20, [165, 108, 89]), (24, 32, [248, 223, 194]), (47, 63, [177, 169, 91]), (5, 60, [84, 125, 182]), (40, 3, [145, 43, 37])],
            "left": [(0, 0, [211, 100, 227]), (10, 20, [70, 201, 65]), (24, 32, [157, 67, 152]), (47, 63, [96, 26, 222]), (5, 60, [228, 218, 82]), (40, 3, [50, 149, 208])],
        ]
        for (name, eye) in [("right", Self.rightEye), ("left", Self.leftEye)] {
            let crop = try #require(EyeCrop.make(eye, frameWidth: 200, frameHeight: 150))
            let rgb = EyeImage.sampleRGB(buffer, mapping: mapping, crop: crop)
            for (row, col, want) in expected[name]! {
                let o = (row * 64 + col) * 3
                for c in 0..<3 {
                    // OpenCV's uint8 resize uses 11-bit fixed point; allow one level of rounding.
                    #expect(abs(rgb[o + c] * 255 - want[c]) <= 1.01, Comment(rawValue: "\(name) (\(row),\(col)) ch\(c): \(rgb[o + c] * 255) vs \(want[c])"))
                }
            }
        }
    }

    @Test func rotatedFrameSamplesUpright() throws {
        // Store the synthetic image rotated 90° counter-clockwise; with orientation .right
        // (rotate 90° clockwise to view) the sampled crop must be identical.
        let upright = try Self.syntheticBuffer(width: 200, height: 150)
        let stored = try Self.rotateCCW(upright)
        let crop = try #require(EyeCrop.make(Self.rightEye, frameWidth: 200, frameHeight: 150))
        let a = EyeImage.sampleRGB(upright, mapping: UprightMapping(bufferWidth: 200, bufferHeight: 150, orientation: .up), crop: crop)
        let b = EyeImage.sampleRGB(stored, mapping: UprightMapping(bufferWidth: 150, bufferHeight: 200, orientation: .right), crop: crop)
        let maxDiff = zip(a, b).map { abs($0 - $1) }.max() ?? 1
        #expect(maxDiff < 1e-5)
    }

    // MARK: helpers

    static func syntheticBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let pb = try TestImages.makeBGRA(width: width, height: height)
        TestImages.fill(pb) { x, y in
            (r: UInt8((x * 7 + y * 3) % 256), g: UInt8((x * 2 + y * 11) % 256), b: UInt8((x * x + y) % 256))
        }
        return pb
    }

    static func rotateCCW(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let dst = try TestImages.makeBGRA(width: h, height: w)
        // Upright (x, y) lives at stored (y, w - 1 - x).
        TestImages.fill(dst) { sx, sy in
            let (r, g, b) = TestImages.read(src, x: w - 1 - sy, y: sx)
            return (r, g, b)
        }
        return dst
    }
}

@Suite struct EyeContourTests {
    @Test func visionSixPointOrderIsKept() throws {
        // Vision's order for the image-left eye, measured on the fixture clip.
        let pts = [CGPoint(x: 897, y: 161), CGPoint(x: 903, y: 155), CGPoint(x: 914, y: 153), CGPoint(x: 922, y: 156), CGPoint(x: 915, y: 159), CGPoint(x: 904, y: 162)]
        let eye = try #require(EyePoints.fromContour(pts, otherEyeCenter: CGPoint(x: 975, y: 147)))
        #expect(eye.ordered == pts)
    }

    @Test func anyStartAndDirection() throws {
        let pts = [CGPoint(x: 988, y: 147), CGPoint(x: 980, y: 143), CGPoint(x: 968, y: 145), CGPoint(x: 961, y: 151), CGPoint(x: 969, y: 151), CGPoint(x: 981, y: 150)]
        let expected = try #require(EyePoints.fromContour(pts, otherEyeCenter: CGPoint(x: 909, y: 157)))
        #expect(expected.ordered == pts)
        let rotatedReversed = Array((pts + pts)[2..<8].reversed())
        let eye = try #require(EyePoints.fromContour(rotatedReversed, otherEyeCenter: CGPoint(x: 909, y: 157)))
        #expect(eye == expected)
    }

    @Test func denseContourIsResampled() throws {
        // Ellipse centred at (100, 50), 40 wide, 16 tall, 16 points, other eye to the right.
        let pts = (0..<16).map { k -> CGPoint in
            let t = Double(k) / 16 * 2 * .pi
            return CGPoint(x: 100 - 20 * cos(t), y: 50 - 8 * sin(t))
        }
        let eye = try #require(EyePoints.fromContour(pts, otherEyeCenter: CGPoint(x: 200, y: 50)))
        #expect(eye.outer == CGPoint(x: 80, y: 50))
        #expect(abs(eye.inner.x - 120) < 1e-9)
        #expect(eye.upperOuter.y < 50 && eye.upperInner.y < 50)
        #expect(eye.lowerOuter.y > 50 && eye.lowerInner.y > 50)
        #expect(eye.upperOuter.x < eye.upperInner.x)
        #expect(eye.lowerOuter.x < eye.lowerInner.x)
    }
}
