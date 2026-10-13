import AVFoundation
import ImageIO

/// What Mirada needs to know about a video file's video track.
public struct VideoTrackInfo: Sendable {
    public let naturalSize: CGSize
    public let nominalFrameRate: Float
    public let duration: CMTime
    public let transform: CGAffineTransform
    public let estimatedDataRate: Float
    /// Color tags copied to the output (primaries, transfer function, matrix).
    public let colorProperties: [String: String]
    public let isHDR: Bool
    public let hasAudio: Bool

    public var orientation: CGImagePropertyOrientation { Self.orientation(for: transform) }

    public static func load(_ asset: AVAsset) async throws -> VideoTrackInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MiradaError.invalidArgument("no video track")
        }
        let (size, fps, transform, rate, formats) = try await track.load(.naturalSize, .nominalFrameRate, .preferredTransform, .estimatedDataRate, .formatDescriptions)
        let duration = try await asset.load(.duration)
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty

        var color: [String: String] = [:]
        var hdr = false
        if let desc = formats.first {
            let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] ?? [:]
            if let p = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String { color[AVVideoColorPrimariesKey] = p }
            if let t = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
                color[AVVideoTransferFunctionKey] = t
                hdr = t == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) || t == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            }
            if let m = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String { color[AVVideoYCbCrMatrixKey] = m }
        }
        return VideoTrackInfo(naturalSize: size, nominalFrameRate: fps, duration: duration, transform: transform,
                              estimatedDataRate: rate, colorProperties: color, isHDR: hdr, hasAudio: hasAudio)
    }

    /// EXIF orientation that makes the stored pixels upright, from a track's
    /// `preferredTransform` (rotations and flips in 90° steps).
    public static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        func s(_ v: CGFloat) -> Int { v > 0.5 ? 1 : (v < -0.5 ? -1 : 0) }
        switch (s(t.a), s(t.b), s(t.c), s(t.d)) {
        case (1, 0, 0, 1): return .up
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored
        case (0, -1, -1, 0): return .rightMirrored
        default: return .up
        }
    }
}
