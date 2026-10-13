@preconcurrency import AVFoundation

/// Decodes a video file to BGRA frames, in order, on demand. Nothing is read
/// ahead of the consumer except what AVAssetReader buffers internally, so
/// memory stays bounded however long the file is.
public final class FileSource: FrameSource, @unchecked Sendable {
    public let url: URL
    public let info: VideoTrackInfo
    public let timeRange: CMTimeRange?
    let asset: AVURLAsset
    let track: AVAssetTrack

    public init(url: URL, timeRange: CMTimeRange? = nil) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MiradaError.inputMissing(url) }
        self.url = url
        self.timeRange = timeRange
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            info = try await VideoTrackInfo.load(asset)
            guard let t = try await asset.loadTracks(withMediaType: .video).first else { throw MiradaError.invalidArgument("no video track") }
            track = t
        } catch let e as MiradaError {
            throw MiradaError.inputUnreadable(url, e.localizedDescription)
        } catch {
            throw MiradaError.inputUnreadable(url, error.localizedDescription)
        }
    }

    /// Frames in presentation order. Each call starts a fresh reader.
    public func frames() -> AsyncThrowingStream<Frame, Error> {
        let state: ReaderState
        do {
            state = try ReaderState(asset: asset, track: track, url: url, timeRange: timeRange, orientation: info.orientation)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream(unfolding: { try state.next() })
    }

    /// Owns the reader; only touched from the stream's sequential `next()` calls.
    private final class ReaderState: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let orientation: CGImagePropertyOrientation
        let url: URL

        init(asset: AVURLAsset, track: AVAssetTrack, url: URL, timeRange: CMTimeRange?, orientation: CGImagePropertyOrientation) throws {
            self.url = url
            self.orientation = orientation
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw MiradaError.inputUnreadable(url, error.localizedDescription)
            }
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            output.alwaysCopiesSampleData = false
            if let timeRange { reader.timeRange = timeRange }
            reader.add(output)
            guard reader.startReading() else {
                throw MiradaError.inputUnreadable(url, reader.error?.localizedDescription ?? "can't start reading")
            }
        }

        func next() throws -> Frame? {
            while let sample = output.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                return Frame(pixelBuffer: pb, time: CMSampleBufferGetPresentationTimeStamp(sample), orientation: orientation)
            }
            if reader.status == .failed {
                throw MiradaError.inputUnreadable(url, reader.error?.localizedDescription ?? "decode failed")
            }
            return nil
        }

        deinit {
            if reader.status == .reading { reader.cancelReading() }
        }
    }
}
