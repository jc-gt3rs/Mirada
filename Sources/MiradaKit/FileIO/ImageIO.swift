import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Still images in and out, as frames. Pixels are kept as stored, with the
/// EXIF orientation carried in `Frame.orientation` and written back.
public enum StillImage {
    public static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    public static func load(_ url: URL) throws -> Frame {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MiradaError.inputMissing(url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw MiradaError.inputUnreadable(url, "not a readable image") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        return Frame(pixelBuffer: try pixelBuffer(from: image), time: .zero, orientation: orientation)
    }

    /// Draws a CGImage into a new IOSurface-backed BGRA buffer (sRGB).
    public static func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else {
            throw MiradaError.internalError("can't allocate \(image.width)x\(image.height) buffer")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw MiradaError.internalError("CGContext") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pb
    }

    public static func write(_ frame: Frame, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let type: UTType = ext == "png" ? .png : (ext == "heic" ? .heic : .jpeg)
        let ci = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard let image = CIContext().createCGImage(ci, from: ci.extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw MiradaError.outputUnwritable(url, "can't encode \(type.preferredFilenameExtension ?? ext)") }
        var props: [CFString: Any] = [kCGImagePropertyOrientation: frame.orientation.rawValue]
        if type != .png { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MiradaError.outputUnwritable(url, "write failed") }
    }
}
