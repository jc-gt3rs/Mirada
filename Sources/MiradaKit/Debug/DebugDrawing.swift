import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Debug rendering: frames to PNG, with optional landmark and crop overlays.
public enum DebugDrawing {
    /// The frame as an upright CGImage.
    public static func uprightImage(_ frame: Frame) -> CGImage? {
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent)
    }

    /// Draws eye points (training order, numbered by colour) and crop boxes.
    public static func overlay(_ image: CGImage, face: FaceLandmarks?) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let face else { return ctx.makeImage() }
        // Flip to top-left origin to match upright pixel coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let colors: [CGColor] = [
            CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1), CGColor(red: 1, green: 0.6, blue: 0, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1), CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 1),
            CGColor(red: 0, green: 0.8, blue: 1, alpha: 1), CGColor(red: 0.6, green: 0.4, blue: 1, alpha: 1),
        ]
        let r = max(1.5, CGFloat(face.interocularPixels) / 60)
        for eye in [face.leftEye, face.rightEye] {
            if let crop = EyeCrop.make(eye, frameWidth: w, frameHeight: h) {
                ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0.95, alpha: 1))
                ctx.setLineWidth(r / 2)
                ctx.stroke(CGRect(x: crop.left, y: crop.top, width: crop.width, height: crop.height))
            }
            for (i, p) in eye.ordered.enumerated() {
                ctx.setFillColor(colors[i])
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }
        return ctx.makeImage()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MiradaError.outputUnwritable(url, "can't create PNG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MiradaError.outputUnwritable(url, "can't write PNG") }
    }
}
